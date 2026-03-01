# remote-claude

모바일 환경에서 Claude Code를 원격으로 사용하기 위한 셋업 가이드.

맥북에서 Claude Code를 실행하고, 외출 시 스마트폰으로 상태를 확인하고 조작할 수 있다.

두 가지 방식을 제공한다:
- **1안 (권장): HAPI** — 모바일 최적화 웹 UI, 설정 간단
- **2안: 직접 구성** — Cloudflare Tunnel + tmux + ntfy 조합, 안정적이지만 모바일 UX 불편

자세한 비교는 [docs/comparison.md](docs/comparison.md) 참고.

---

## 1안: HAPI (권장)

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

#### 1. 맥북: 실행

```bash
caffeinate -s -- npx @twsxtd/hapi hub --relay
```

터미널에 URL과 QR 코드가 표시된다.

#### 2. 스마트폰: 접속

표시된 URL을 브라우저에서 열거나 QR 코드를 스캔한다. 추가 앱 설치 불필요.

### 사용 흐름

1. 맥북에서 `caffeinate -s -- npx @twsxtd/hapi hub --relay` 실행
2. 외출
3. Claude가 입력 대기 → 폰에 푸시 알림 수신
4. 브라우저에서 HAPI UI 열기
5. 승인 버튼 탭 또는 텍스트/음성 입력

### 주의사항

- **맥북 잠자기**: `caffeinate -s`가 맥북 잠자기를 방지한다. 전원에 연결된 상태에서만 동작.
- **릴레이 보안**: WireGuard + TLS로 E2E 암호화. 릴레이 서버는 암호화된 패킷만 전달하며 내용을 볼 수 없다.
- **데이터 로컬 유지**: 코드와 세션 데이터가 맥북을 떠나지 않는다.

---

## 2안: 직접 구성

HAPI가 맞지 않거나 더 세밀한 제어가 필요한 경우, 검증된 도구들을 조합하여 구성할 수 있다.

### 아키텍처

```
┌─ 맥북 ──────────────────────────────┐
│                                      │
│  tmux                                │
│  ├─ window 0: claude (프로젝트 A)    │
│  ├─ window 1: claude (프로젝트 B)    │
│  └─ ...                             │
│                                      │
│  Claude 훅 → curl ntfy.sh/토픽       │
│  cloudflared (SSH 터널)              │
└──────────────────────────────────────┘
        │                    │
        │ HTTPS              │ Cloudflare Tunnel
        ▼                    │
   ntfy.sh 서버              │
        │                    │
        │ 푸시 알림           │ SSH
        ▼                    ▼
┌─ 스마트폰 ───────────────────────────┐
│                                      │
│  Ntfy 앱: 알림 수신                  │
│  Termius: SSH → tmux attach          │
└──────────────────────────────────────┘
```

### 사용하는 도구

| 도구 | 역할 |
|------|------|
| [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) | 맥북 SSH를 인터넷에 안전하게 노출 |
| [tmux](https://github.com/tmux/tmux) | 터미널 세션 유지 |
| [Ntfy](https://ntfy.sh/) | 웹훅 기반 푸시 알림 (무료, 오픈소스) |
| [Termius](https://termius.com/) | 스마트폰 SSH 클라이언트 |
| caffeinate | macOS 내장 잠자기 방지 |

### 셋업

#### 1. 맥북: 패키지 설치

```bash
brew install cloudflared tmux
```

#### 2. Cloudflare Tunnel 구성

Cloudflare 계정과 Cloudflare에 등록된 도메인이 필요하다.

```bash
# Cloudflare 로그인
cloudflared tunnel login

# 터널 생성
cloudflared tunnel create macbook-ssh

# DNS 라우팅 (예: ssh.example.com)
cloudflared tunnel route dns macbook-ssh ssh.example.com
```

`~/.cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /Users/<USERNAME>/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: ssh.example.com
    service: ssh://localhost:22
  - service: http_status:404
```

```bash
# 서비스로 등록 (맥북 부팅 시 자동 시작)
sudo cloudflared service install
```

#### 3. 맥북: SSH(원격 로그인) 활성화

**시스템 설정** → **일반** → **공유** → **원격 로그인** 활성화

#### 4. 맥북: Claude Code 세션 시작

```bash
tmux new-session -s claude 'caffeinate -s -- bash'
```

세션 안에서 `claude` 실행. 세션에서 빠져나오기: `Ctrl+A`, `D`

#### 5. 맥북: 푸시 알림 훅 설정

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
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/notify.sh"
          }
        ]
      }
    ]
  }
}
```

Ntfy 토픽을 `~/.zshrc`에 추가:

```bash
export NTFY_TOPIC="claude-notify-$(openssl rand -hex 4)"
```

#### 6. 스마트폰 설정

1. **Ntfy** 앱 설치 → 맥북과 같은 토픽 구독
2. **Termius** 앱 설치 → 호스트: `ssh.example.com`, 포트: 22

### 사용 흐름

1. 맥북에서 tmux 세션 시작 + Claude Code 실행
2. 외출
3. Claude가 입력 대기 → 폰에 푸시 알림 수신
4. Termius로 SSH 접속 → `tmux attach -t claude`
5. Claude와 상호작용

### 주의사항

- **맥북 잠자기**: `caffeinate -s`가 tmux 세션과 생명주기를 같이 한다.
- **SSH 보안**: 터널 도메인을 아는 사람은 접속 시도 가능. SSH 키 인증 권장. 필요시 [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/)로 MFA 추가.
- **Ntfy 보안**: 알림에 민감 정보 미포함. 토픽 이름을 랜덤하게 설정.
- **Ntfy 일일 한도**: 무료 250건/일. debounce(5분)로 충분히 여유.

---

## 참고

- [Claude Code On-The-Go](https://granda.org/en/2026/01/02/claude-code-on-the-go/) — 원격 VM에서 Claude Code를 모바일로 운영하는 블로그 글
- [HAPI](https://github.com/tiann/hapi) — 1안에서 사용하는 도구
- [Happy](https://github.com/slopus/happy) — 유사 도구 (중앙 서버 경유 방식, 검토 후 기각)
- [docs/comparison.md](docs/comparison.md) — 1안 vs 2안 상세 비교
- [docs/technical-decisions.md](docs/technical-decisions.md) — 2안의 기술 스택 선택 배경
