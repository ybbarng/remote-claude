# remote-claude

모바일 환경에서 Claude Code를 원격으로 사용하기 위한 셋업 가이드.

맥북에서 Claude Code를 실행하고, 외출 시 스마트폰으로 상태를 확인하고 조작할 수 있다.

세 가지 방식을 검토했다:
- **1안: HAPI** — 모바일 최적화 웹 UI, 설정 간단하지만 초기 버그 존재
- **2안 (현재 사용): 개인 서버 경유** — SSH 리버스 터널 + mosh + tmux 조합
- **3안: Cloudflare Tunnel** — 도메인 필요, 안정적이지만 mosh 불가

자세한 비교는 [docs/comparison.md](docs/comparison.md) 참고.

---

## 1안: HAPI

[HAPI](https://github.com/tiann/hapi)는 Claude Code를 모바일에서 원격 제어할 수 있는 오픈소스 도구다. 브라우저에서 승인 버튼 탭, 출력 확인, 음성 입력 등을 지원한다.

### 아키텍처

```
┌─ 맥북 ──────────────────────────────┐
│                                      │
│  caffeinate -s                       │
│  └─ hapi (Claude Code를 감싸서 실행) │
│                                      │
└──────────────────────────────────────┘
        │
        │ WireGuard + TLS (릴레이)
        ▼
┌─ 스마트폰 ───────────────────────────┐
│                                      │
│  브라우저로 HAPI 웹 UI 접속          │
│  ├─ Claude 출력 확인                 │
│  ├─ 승인 버튼 탭                     │
│  └─ 텍스트/음성 입력                 │
└──────────────────────────────────────┘
```

### 셋업

```bash
caffeinate -s -- npx @twsxtd/hapi hub --relay
```

터미널에 URL과 QR 코드가 표시된다. 스마트폰 브라우저에서 열거나 QR 코드를 스캔.

### 현재 상태

초기 버그로 인해 사용하지 않음. 프로젝트가 안정화되면 재검토 예정.

---

## 2안: 개인 서버 경유 (현재 사용)

개인 서버를 SSH 리버스 터널의 중계점으로 사용하여, mosh + tmux로 모바일에서 맥북에 접속한다.

### 아키텍처

```
┌─ 맥북 ──────────────────────────────┐
│                                      │
│  tmux (세션 유지)                    │
│  ├─ window 1: claude (프로젝트 A)   │
│  ├─ window 2: claude (프로젝트 B)   │
│  └─ ...                             │
│                                      │
│  autossh (리버스 터널, launchd)      │
│  └─ -R 2222:localhost:22 → 서버     │
│                                      │
│  Claude 훅 → curl ntfy.sh/토픽      │
└──────────────────────────────────────┘
        │
        │ SSH 리버스 터널 (autossh)
        ▼
┌─ 개인 서버 ─────────────────────────┐
│                                      │
│  claude 유저 (프록시 전용, 셸 없음) │
│  localhost:2222 → 맥북:22           │
└──────────────────────────────────────┘
        ▲
        │ mosh (UDP)
        │
┌─ 스마트폰 ───────────────────────────┐
│                                      │
│  Termius: mosh → claude@서버         │
│  → 자동으로 맥북 tmux 세션 연결     │
└──────────────────────────────────────┘
```

### 사용하는 도구

| 도구 | 역할 |
|------|------|
| [autossh](https://www.harding.motd.ca/autossh/) | SSH 리버스 터널 자동 유지 |
| [mosh](https://mosh.org/) | UDP 기반 원격 접속 (네트워크 전환 시 끊김 없음) |
| [tmux](https://github.com/tmux/tmux) | 터미널 세션 유지, 다중 윈도우 |
| [Termius](https://termius.com/) | 스마트폰 SSH/mosh 클라이언트 |
| [Ntfy](https://ntfy.sh/) | 웹훅 기반 푸시 알림 (무료, 오픈소스) |

### 셋업

#### 1. 맥북: 패키지 설치

```bash
brew install autossh tmux
```

macOS SSH(원격 로그인) 활성화: **시스템 설정** → **일반** → **공유** → **원격 로그인**

#### 2. 개인 서버: mosh 설치

```bash
sudo apt-get install -y mosh
```

방화벽에서 mosh UDP 포트 개방:

```bash
sudo ufw allow 60000:61000/udp
```

#### 3. 개인 서버: 프록시 전용 유저 생성

프록시 스크립트 생성:

```bash
sudo nano /usr/local/bin/claude-proxy
```

```bash
#!/bin/bash
# claude@서버 전용 로그인 셸
# mosh/SSH가 -c 옵션으로 명령을 실행하면 (예: mosh-server) 그대로 실행
if [ "$1" = "-c" ]; then
    exec bash -c "$2"
fi
# 일반 로그인 시 맥북의 tmux 세션에 자동 연결
# autossh가 맥북:22 → 서버:2222 리버스 터널을 유지함
exec ssh -p 2222 -tt <맥북유저>@localhost "/usr/local/bin/tmux new-session -t claude || /usr/local/bin/tmux new -s claude"
```

```bash
sudo chmod 755 /usr/local/bin/claude-proxy
echo '/usr/local/bin/claude-proxy' | sudo tee -a /etc/shells
```

유저 생성 (프록시 전용, 셸/sudo 없음):

```bash
sudo useradd -m -s /usr/local/bin/claude-proxy claude
sudo passwd -l claude
```

SSH 키 디렉토리 준비:

```bash
sudo mkdir -p /home/claude/.ssh
sudo chmod 700 /home/claude/.ssh
sudo touch /home/claude/.ssh/authorized_keys
sudo chmod 600 /home/claude/.ssh/authorized_keys
sudo chown -R claude:claude /home/claude/.ssh
```

#### 4. SSH 키 설정

두 구간의 SSH 키가 필요하다.

**서버 → 맥북** (리버스 터널 경유):

```bash
# 서버에서 claude 유저의 키 생성
sudo -u claude ssh-keygen -t ed25519 -f /home/claude/.ssh/id_ed25519 -N "" -C "claude@서버"

# 공개키를 맥북의 ~/.ssh/authorized_keys에 추가
sudo cat /home/claude/.ssh/id_ed25519.pub
```

**스마트폰(Termius) → 서버**:

Termius에서 ED25519 키 생성 후, 공개키를 서버의 `/home/claude/.ssh/authorized_keys`에 추가.

#### 5. 맥북: autossh 리버스 터널 (launchd)

`~/Library/LaunchAgents/com.<유저>.autossh-tunnel.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.<유저>.autossh-tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/autossh</string>
        <string>-M</string>
        <string>0</string>
        <string>-N</string>
        <string>-R</string>
        <string>2222:localhost:22</string>
        <string>-o</string>
        <string>ServerAliveInterval 30</string>
        <string>-o</string>
        <string>ServerAliveCountMax 3</string>
        <string><서버 호스트></string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/autossh-tunnel.err</string>
    <key>StandardOutPath</key>
    <string>/tmp/autossh-tunnel.out</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>AUTOSSH_GATETIME</key>
        <string>0</string>
    </dict>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.<유저>.autossh-tunnel.plist
```

#### 6. 맥북: Claude Code 세션 시작

```bash
tmux new-session -s claude
```

세션 안에서 `claude` 실행. 세션에서 빠져나오기: `Ctrl+A`, `D`

#### 7. 스마트폰: Termius 설정

Termius에서 호스트 추가:
- **Hostname**: 서버 주소
- **Port**: 22
- **Username**: `claude`
- **Key**: Termius에서 생성한 ED25519 키
- **Mosh**: 활성화

### 사용 흐름

1. 맥북에서 tmux 세션 시작 + Claude Code 실행 (autossh 터널은 launchd가 자동 관리)
2. 외출
3. Claude가 입력 대기 → 폰에 ntfy 푸시 알림 수신 (선택)
4. Termius에서 호스트 탭 → mosh로 서버 접속 → 자동으로 맥북 tmux 세션 연결
5. Claude와 상호작용

### 다중 클라이언트

폰과 맥북에서 동시에 tmux 세션을 사용할 수 있다. 프록시 스크립트가 `tmux new-session -t claude`를 사용하므로:
- 각 클라이언트가 **독립적인 해상도**로 렌더링
- 같은 윈도우를 공유하되 **다른 윈도우를 각자 볼 수 있음**
- `tmux.conf`의 `aggressive-resize on` 설정과 함께 동작

### 보안

- **claude 유저**: 프록시 전용. 로그인 셸이 프록시 스크립트이므로 서버 셸 접근 불가. sudo 불가. 비밀번호 잠금.
- **2222번 포트**: 서버의 localhost에서만 접근 가능. 외부에 노출되지 않음.
- **SSH 키 인증**: 비밀번호 인증 없이 키로만 접속.

### 주의사항

- **맥북 잠자기**: `caffeinate -s`로 잠자기 방지 필요. 전원 연결 상태에서만 동작.
- **다른 사용자 추가**: 같은 서버에서 포트 번호만 다르게 하여 별도 유저 추가 가능 (예: `cheolsu` 유저, 3333번 포트).

---

## 푸시 알림 (선택)

Claude가 사용자 입력을 기다릴 때 스마트폰으로 알림을 보낸다. [Ntfy](https://ntfy.sh/) 공용 서버를 사용.

`~/.claude/hooks/notify.sh` 생성 (저장소의 [hooks/notify.sh](hooks/notify.sh) 참고):

```bash
#!/bin/bash
NTFY_TOPIC="${NTFY_TOPIC:-my-claude-topic}"
DEBOUNCE_SECONDS=${NTFY_DEBOUNCE:-300}
LAST_FILE="/tmp/ntfy-last-notify"

LAST=$(cat "$LAST_FILE" 2>/dev/null || echo 0)
NOW=$(date +%s)

if [ $((NOW - LAST)) -ge "$DEBOUNCE_SECONDS" ]; then
  curl -s -d "Claude가 입력을 기다리고 있습니다" "ntfy.sh/${NTFY_TOPIC}" || \
    (sleep 5 && curl -s -d "Claude가 입력을 기다리고 있습니다" "ntfy.sh/${NTFY_TOPIC}")
  echo "$NOW" > "$LAST_FILE"
fi
```

```bash
chmod +x ~/.claude/hooks/notify.sh
```

`~/.claude/settings.json`에 훅 등록:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/notify.sh" }]
      }
    ]
  }
}
```

Ntfy 토픽을 `~/.zshrc`에 추가:

```bash
export NTFY_TOPIC="claude-notify-$(openssl rand -hex 4)"
```

스마트폰에 **Ntfy** 앱 설치 → 같은 토픽 구독.

---

## 3안: Cloudflare Tunnel

Cloudflare 계정과 도메인이 필요하다. mosh(UDP)를 지원하지 않아 SSH만 사용 가능. 자세한 내용은 [docs/technical-decisions.md](docs/technical-decisions.md) 참고.

---

## 참고

- [Claude Code On-The-Go](https://granda.org/en/2026/01/02/claude-code-on-the-go/) — 원격 VM에서 Claude Code를 모바일로 운영하는 블로그 글
- [HAPI](https://github.com/tiann/hapi) — 1안에서 사용하는 도구
- [Happy](https://github.com/slopus/happy) — 유사 도구 (중앙 서버 경유 방식, 검토 후 기각)
- [docs/comparison.md](docs/comparison.md) — 방식별 상세 비교
- [docs/technical-decisions.md](docs/technical-decisions.md) — 기술 스택 선택 배경
