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
│  ZeroTier (항상 켜짐)                │
└──────────────────────────────────────┘
        │                    │
        │ HTTPS              │ ZeroTier P2P
        ▼                    │
   ntfy.sh 서버              │
        │                    │
        │ 푸시 알림           │ SSH (또는 mosh)
        ▼                    ▼
┌─ 스마트폰 ───────────────────────────┐
│                                      │
│  Ntfy 앱: 알림 수신 (VPN 불필요)     │
│  ZeroTier: 필요할 때만 켜기          │
│  Termius: SSH → tmux attach          │
└──────────────────────────────────────┘
```

## 사용하는 도구

| 도구 | 역할 |
|------|------|
| [ZeroTier](https://www.zerotier.com/) | 맥북-스마트폰 간 P2P VPN (가상 LAN) |
| [tmux](https://github.com/tmux/tmux) | 터미널 세션 유지 |
| [mosh](https://mosh.org/) | 네트워크 전환에도 끊기지 않는 SSH 대체 (선택사항) |
| [Ntfy](https://ntfy.sh/) | 웹훅 기반 푸시 알림 (무료, 오픈소스) |
| [Termius](https://termius.com/) | 스마트폰 SSH 클라이언트 |
| caffeinate | macOS 내장 잠자기 방지 |

## 셋업

### 1. 맥북: 패키지 설치

```bash
brew install --cask zerotier-one
brew install tmux mosh
```

### 2. ZeroTier 네트워크 구성

1. [my.zerotier.com](https://my.zerotier.com)에 가입
2. **Create A Network** → 16자리 Network ID 생성
3. Access Control을 **Private**으로 유지 (기본값)
4. 맥북에서 네트워크 가입:

```bash
sudo zerotier-cli join <NETWORK_ID>
```

5. 웹 콘솔 → Members에서 맥북을 **승인** (Auth 체크)
6. 필요시 고정 IP 지정 가능

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

세션에서 빠져나오기: `Ctrl+B`, `D`

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

1. **ZeroTier One** 앱 설치 → Network ID 입력 → 가입
2. 웹 콘솔에서 스마트폰 **승인**
3. **Ntfy** 앱 설치 → 맥북과 같은 토픽 구독
4. **Termius** 앱 설치 → 호스트 추가:
   - Host: 맥북의 ZeroTier IP (예: `10.147.20.1`)
   - Port: 22
   - Username: 맥북 사용자 이름
5. (선택) Termius에서 Mosh 모드 활성화

맥북의 ZeroTier IP 확인:

```bash
sudo zerotier-cli listnetworks
```

## 사용 흐름

1. 맥북에서 tmux 세션 시작 + Claude Code 실행
2. 외출
3. Claude가 입력 대기 → 폰에 푸시 알림 수신 (VPN 불필요)
4. 폰에서 ZeroTier 켜기
5. Termius로 SSH 접속 → `tmux attach -t claude`
6. Claude와 상호작용
7. 작업 끝나면 ZeroTier 꺼도 됨

## mosh (선택사항)

mosh를 사용하면 네트워크가 전환(와이파이 ↔ 셀룰러)되거나 잠시 끊겨도 재접속 없이 자동 복구된다. SSH가 자주 끊기는 환경에서 유용하다.

- SSH: 끊기면 재접속 → `tmux attach` 필요
- mosh: 자동 복구, 바로 이전 화면 유지

tmux와 함께 사용하면 mosh가 죽어도 tmux 세션은 남아 있어 SSH로 복구 가능하다.

Termius에서 호스트 설정 시 Mosh 토글을 켜면 된다.

## 주의사항

- **맥북 잠자기**: `caffeinate -s`가 실행 중이어야 외부 접속 가능. tmux 세션 시작 시 자동으로 실행되도록 구성되어 있다.
- **ZeroTier 포트**: UDP 9993을 사용한다. 네트워크 방화벽이 차단하면 릴레이를 통해 연결되며, 릴레이 경유 시에도 E2E 암호화가 유지된다.
- **Ntfy 보안**: 공용 서버를 사용하므로 알림 내용에 민감한 정보를 포함하지 않는다. 토픽 이름을 길고 랜덤하게 설정하면 다른 사람이 추측하기 어렵다.
- **macOS 방화벽**: mosh 사용 시 UDP 60000~61000 포트의 수신 연결을 허용해야 할 수 있다.

## 참고

- [Claude Code On-The-Go](https://granda.org/en/2026/01/02/claude-code-on-the-go/) — 원격 VM에서 Claude Code를 모바일로 운영하는 블로그 글. 이 저장소는 원격 VM 대신 로컬 맥북을 사용하는 변형이다.
