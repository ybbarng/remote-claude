# remote-claude

모바일 환경에서 Claude Code를 원격으로 사용하기 위한 셋업 가이드.

맥북에서 Claude Code를 실행하고, 외출 시 스마트폰으로 상태를 확인하고 조작할 수 있다.

## 아키텍처

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

## 사용하는 도구

| 도구 | 역할 |
|------|------|
| [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) | 맥북 SSH를 인터넷에 안전하게 노출 |
| [tmux](https://github.com/tmux/tmux) | 터미널 세션 유지 |
| [mosh](https://mosh.org/) | 네트워크 전환에도 끊기지 않는 SSH 대체 (선택사항) |
| [Ntfy](https://ntfy.sh/) | 웹훅 기반 푸시 알림 (무료, 오픈소스) |
| [Termius](https://termius.com/) | 스마트폰 SSH 클라이언트 |
| caffeinate | macOS 내장 잠자기 방지 |

## 셋업

### 1. 맥북: 패키지 설치

```bash
brew install cloudflared tmux mosh
```

### 2. Cloudflare Tunnel 구성

#### 2-1. Cloudflare 계정 및 도메인

Cloudflare Tunnel을 사용하려면 Cloudflare 계정과 Cloudflare에 등록된 도메인이 필요하다.

1. [Cloudflare](https://dash.cloudflare.com/sign-up)에 가입
2. 도메인을 Cloudflare에 추가 (기존 도메인 또는 Cloudflare에서 구매)

#### 2-2. 터널 생성

```bash
# Cloudflare 로그인
cloudflared tunnel login

# 터널 생성
cloudflared tunnel create macbook-ssh

# 터널 ID 확인 (이후 설정에 필요)
cloudflared tunnel list
```

#### 2-3. DNS 라우팅 설정

```bash
# 터널에 DNS 레코드 연결 (예: ssh.example.com)
cloudflared tunnel route dns macbook-ssh ssh.example.com
```

#### 2-4. 터널 설정 파일 작성

`~/.cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /Users/<USERNAME>/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: ssh.example.com
    service: ssh://localhost:22
  - service: http_status:404
```

#### 2-5. 터널 실행

```bash
# 포그라운드 실행 (테스트용)
cloudflared tunnel run macbook-ssh

# 백그라운드 서비스로 등록 (상시 실행)
sudo cloudflared service install
```

### 3. 맥북: SSH(원격 로그인) 활성화

**시스템 설정** → **일반** → **공유** → **원격 로그인** 활성화

또는:

```bash
sudo systemsetup -setremotelogin on
```

### 4. 맥북: Claude Code 세션 시작

```bash
tmux new-session -s claude 'caffeinate -s -- bash'
```

- `caffeinate -s`: 전원 연결 시 잠자기 방지
- tmux 세션이 종료되면 caffeinate도 자동 종료

세션 안에서 Claude Code 실행:

```bash
claude
```

세션에서 빠져나오기: `Ctrl+A`, `D` (tmux.conf.example 적용 시)

### 5. 맥북: 푸시 알림 훅 설정

Claude가 사용자 입력을 기다릴 때 알림을 보내도록 훅을 설정한다.

#### 5-1. 알림 스크립트 생성

`~/.claude/hooks/notify.sh`:

```bash
#!/bin/bash
NTFY_TOPIC="${NTFY_TOPIC:-my-claude-topic}"
DEBOUNCE_SECONDS=${NTFY_DEBOUNCE:-300}  # 기본 5분
LAST_FILE="/tmp/ntfy-last-notify"

LAST=$(cat "$LAST_FILE" 2>/dev/null || echo 0)
NOW=$(date +%s)

if [ $((NOW - LAST)) -ge "$DEBOUNCE_SECONDS" ]; then
  curl -s -d "Claude가 입력을 기다리고 있습니다" "ntfy.sh/${NTFY_TOPIC}" || \
    (sleep 5 && curl -s -d "Claude가 입력을 기다리고 있습니다" "ntfy.sh/${NTFY_TOPIC}")
  echo "$NOW" > "$LAST_FILE"
fi
```

- 마지막 알림으로부터 5분 이내의 알림은 억제 (debounce)
- 활발히 작업 중일 때는 알림이 오지 않고, 자리를 비웠을 때만 수신
- ntfy 무료 플랜의 하루 250건 제한에 여유를 확보 (5분 간격 시 하루 최대 288건이지만, 21시간 연속 알림은 비현실적)
- `NTFY_DEBOUNCE` 환경 변수로 간격 조절 가능

```bash
chmod +x ~/.claude/hooks/notify.sh
```

#### 5-2. Claude Code 훅 등록

`~/.claude/settings.json`에 추가:

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

#### 5-3. Ntfy 토픽 설정

환경 변수로 토픽 이름을 지정한다. 추측하기 어려운 이름을 사용할 것.

```bash
export NTFY_TOPIC="claude-notify-$(openssl rand -hex 4)"
echo "토픽: $NTFY_TOPIC"
```

이 값을 `~/.zshrc` 등에 추가하면 영구적으로 유지된다.

### 6. 스마트폰 설정

1. **Ntfy** 앱 설치 → 맥북과 같은 토픽 구독
2. **Termius** 앱 설치 → 호스트 추가:
   - Host: 터널에 연결한 도메인 (예: `ssh.example.com`)
   - Port: 22
   - Username: 맥북 사용자 이름
3. (선택) Termius에서 Mosh 모드 활성화

## 사용 흐름

1. 맥북에서 tmux 세션 시작 + Claude Code 실행
2. 외출
3. Claude가 입력 대기 → 폰에 푸시 알림 수신
4. Termius로 SSH 접속 → `tmux attach -t claude`
5. Claude와 상호작용

## mosh (선택사항)

mosh를 사용하면 네트워크가 전환(와이파이 ↔ 셀룰러)되거나 잠시 끊겨도 재접속 없이 자동 복구된다. SSH가 자주 끊기는 환경에서 유용하다.

- SSH: 끊기면 재접속 → `tmux attach` 필요
- mosh: 자동 복구, 바로 이전 화면 유지

tmux와 함께 사용하면 mosh가 죽어도 tmux 세션은 남아 있어 SSH로 복구 가능하다.

Termius에서 호스트 설정 시 Mosh 토글을 켜면 된다.

단, Cloudflare Tunnel은 TCP만 프록시하므로 mosh(UDP)는 터널을 통해 사용할 수 없다. mosh를 쓰려면 같은 네트워크(LAN)에 있거나 별도 VPN이 필요하다.

## 주의사항

- **맥북 잠자기**: `caffeinate -s`가 실행 중이어야 외부 접속 가능. tmux 세션 시작 시 자동으로 실행되도록 구성되어 있다.
- **cloudflared 상시 실행**: `sudo cloudflared service install`로 서비스 등록하면 맥북 부팅 시 자동 시작된다.
- **Ntfy 보안**: 공용 서버를 사용하므로 알림 내용에 민감한 정보를 포함하지 않는다. 토픽 이름을 길고 랜덤하게 설정하면 다른 사람이 추측하기 어렵다.
- **SSH 보안**: Cloudflare Tunnel은 SSH 포트를 인터넷에 직접 열지 않지만, 터널 도메인을 아는 사람은 SSH 접속을 시도할 수 있다. 강력한 비밀번호 또는 SSH 키 인증을 사용할 것. 필요시 [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/)로 추가 인증(이메일, MFA 등)을 설정할 수 있다.

## 참고

- [Claude Code On-The-Go](https://granda.org/en/2026/01/02/claude-code-on-the-go/) — 원격 VM에서 Claude Code를 모바일로 운영하는 블로그 글. 이 저장소는 원격 VM 대신 로컬 맥북을 사용하는 변형이다.
