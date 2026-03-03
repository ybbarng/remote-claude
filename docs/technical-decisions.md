# 기술 검토 문서

이 문서는 remote-claude 구성에서 각 기술 스택을 선택한 배경과 검토 과정을 정리한다.

## 목차

1. [네트워크: 맥북-스마트폰 연결 방법](#1-네트워크-맥북-스마트폰-연결-방법)
2. [푸시 알림: Claude 상태 알림](#2-푸시-알림-claude-상태-알림)
3. [세션 유지: tmux + caffeinate](#3-세션-유지-tmux--caffeinate)
4. [원격 접속: SSH vs mosh](#4-원격-접속-ssh-vs-mosh)
5. [모바일 클라이언트: Termius](#5-모바일-클라이언트-termius)

---

## 1. 네트워크: 맥북-스마트폰 연결 방법

### 요구사항

- 맥북에서 이미 회사 Tailscale VPN을 사용 중
- 회사 인프라를 건드리지 않고 개인 스마트폰에서 맥북에 SSH 접속
- 맥북의 기존 네트워크(인터넷, 회사 VPN)에 영향 없어야 함
- 무료이고 상업적 사용에 라이선스 제한이 없어야 함

### 검토한 후보

#### Tailscale Device Sharing

회사 Tailscale 관리자가 맥북을 개인 Tailscale 계정에 공유하는 방식.

- 장점: 가장 깔끔한 구성. 추가 소프트웨어 불필요. 공유된 기기는 quarantine 상태(인바운드만 허용)로 SSH 접속에 문제 없음.
- 단점: 회사 관리자(Owner/Admin/IT admin)의 협조 필요. 관리자가 거부하면 불가.
- 참고: https://tailscale.com/kb/1084/sharing

#### Tailscale 두 번째 인스턴스 (userspace mode)

오픈소스 `tailscaled`를 userspace networking 모드로 별도 실행하여 개인 tailnet에 연결.

- 장점: 관리자 협조 불필요. 회사 GUI Tailscale과 독립적으로 동작.
- 단점: macOS에서 GUI 앱이 아닌 오픈소스 빌드(`brew install --formula tailscale`)가 필요. userspace 모드에서 SSH 인바운드 수신이 제한적. 설정 복잡도 높음. 회사 보안 정책 위반 가능성.
- 참고: https://github.com/tailscale/tailscale/wiki/Tailscaled-on-macOS

#### ZeroTier

맥북과 스마트폰에 ZeroTier를 설치하여 가상 LAN 구성.

- 장점: 관리자 협조 불필요. Tailscale과 동일한 P2P 메시 VPN 개념으로 익숙. 기존 네트워크(인터넷, Tailscale)에 영향 없음. 고정 IP 지정 가능. 설정 간단.
- 단점: **무료 플랜이 개인/비상업 용도로 제한됨.** 가격 페이지에 "Just don't try to run your business with it"으로 명시. 업무 용도의 맥북-폰 연결은 상업적 사용에 해당할 수 있음. 유료 플랜은 월 $18. Tailscale(WireGuard, 코드 ~4,000줄)과 달리 자체 프로토콜 사용으로 공격 표면이 넓음.
- 참고: https://www.zerotier.com/pricing/

#### Cloudflare Tunnel

맥북에서 cloudflared를 실행하여 SSH를 Cloudflare 네트워크를 통해 노출.

- 장점: 무료 (상업적 사용 포함). 관리자 협조 불필요. VPN 없이 인터넷 어디서든 접속 가능. 폰에 추가 VPN 앱 불필요 (SSH 클라이언트만 있으면 됨). SSH 포트를 인터넷에 직접 열지 않음. Cloudflare Access로 MFA 등 추가 인증 가능.
- 단점: Cloudflare 서버를 경유하므로 레이턴시 추가. DNS 및 터널 라우팅 설정이 필요. Cloudflare 계정과 도메인이 필요 (도메인 연 ~$10). **mosh(UDP)는 TCP만 프록시하므로 사용 불가.**

#### 개인 서버 경유 — SSH 리버스 터널 (선택)

공인 IP가 있는 개인 서버에 autossh로 리버스 터널을 유지하고, 폰에서 mosh로 서버에 접속하면 자동으로 맥북 tmux 세션에 연결.

- 장점: 무료 (기존 서버 활용). mosh(UDP) 사용 가능. 관리자 협조 불필요. 각 도구(autossh, mosh, tmux)가 오래 검증됨. 전체 구조를 직접 통제.
- 단점: 공인 IP가 있는 서버가 필요. autossh, 서버 유저, mosh 등 관리 포인트가 많음. 서버가 다운되면 접속 불가.

### 선택 이유: 개인 서버 경유 (SSH 리버스 터널)

1. **mosh 지원**: 모바일 환경에서 네트워크 전환(와이파이 ↔ 셀룰러) 시 끊김 없는 접속이 가장 중요한 요구사항. Cloudflare Tunnel은 TCP만 프록시하므로 mosh 사용 불가
2. **무료**: 이미 보유한 개인 서버를 활용하므로 추가 비용 없음
3. **독립성**: 회사 Tailscale 관리자에게 의존하지 않음. 특정 서비스에 종속되지 않음
4. **보안**: 프록시 전용 유저(셸/sudo 없음, 비밀번호 잠금). 리버스 터널 포트는 서버 localhost에서만 접근 가능. SSH 키 인증만 허용
5. **확장성**: 같은 서버에서 포트만 다르게 하여 다른 사용자 추가 가능

### 기각된 후보 요약

| 후보 | 기각 사유 |
|------|----------|
| Tailscale Device Sharing | 회사 관리자 협조 필요 |
| Tailscale 두 번째 인스턴스 | 설정 복잡, SSH 인바운드 제한적, 보안 정책 위반 가능 |
| ZeroTier | 무료 플랜이 비상업 용도 한정, 유료는 월 $18 |
| Cloudflare Tunnel | mosh(UDP) 사용 불가. 개인 서버가 있으므로 불필요 |

---

## 2. 푸시 알림: Claude 상태 알림

### 요구사항

- Claude가 사용자 입력을 기다릴 때 스마트폰으로 알림
- VPN 연결 여부와 무관하게 수신 가능해야 함
- 설정이 단순해야 함

### 검토한 후보

#### Ntfy 셀프호스팅 (맥북에서 서버 실행)

- 장점: 완전한 데이터 통제
- 단점: 스마트폰이 맥북의 Ntfy 서버에 접속해야 하므로 VPN 연결 필수. 푸시 알림을 받기 위해 항상 VPN을 켜놔야 하는 것은 사용 흐름에 맞지 않음

#### Pushover

- 장점: 안정적. API 단순.
- 단점: $5 일회성 구매 필요 (iOS/Android 각각)

#### Bark

- 장점: 오픈소스, 무료
- 단점: iOS 전용. Android 사용자와 공유 불가

#### Ntfy 공용 서버 (선택)

- 장점: 무료. 가입 불필요. 오픈소스. curl 한 줄로 알림 전송 가능. APNs/FCM을 통한 표준 푸시이므로 VPN 불필요. iOS/Android 모두 지원.
- 단점: 공용 서버에 알림 내용이 전달됨 (민감 정보 미포함으로 대응)

### 선택 이유: Ntfy 공용 서버 (ntfy.sh)

1. **VPN 독립**: `맥북 → ntfy.sh → APNs/FCM → 폰` 경로로, VPN 연결 없이 알림 수신 가능. "알림 먼저 받고 → SSH 접속" 흐름에 부합
2. **제로 설정**: 가입 없이 토픽 이름만 정하면 바로 사용
3. **Rate limit 충분**: debounce 적용 시 일일 한도 초과 불가 (아래 상세)
4. **보안 대응**: 토픽 이름을 랜덤하게 설정(예: `claude-notify-a8f3k2x9`)하여 추측 방지. 알림 본문에 민감 정보를 넣지 않으면 충분

### Rate Limit 상세

| 항목 | 값 |
|------|-----|
| 일일 발행 한도 | 250건 (매일 자정 UTC 리셋) |
| 버스트 | 60건 |
| 회복 속도 | 5초당 1건 |
| 최대 토큰 | 60개 |
| 완전 복구 시간 | 5분 |
| 초과 시 응답 | 429 Too Many Requests |

### Debounce 전략

일일 250건 제한과 활발한 작업 시 알림 과다를 방지하기 위해 debounce를 적용한다.

- 마지막 알림으로부터 일정 시간(기본 5분) 이내의 알림은 억제
- 활발히 작업 중일 때는 알림이 오지 않고, 자리를 비웠을 때만 수신
- 5분 간격 기준 하루 최대 288건이지만, 21시간 연속 알림은 비현실적이므로 250건 한도를 초과할 일 없음
- `NTFY_DEBOUNCE` 환경 변수로 간격 조절 가능
- 전송 실패 시 5초 후 1회 재시도

---

## 3. 세션 유지: tmux + caffeinate

### 요구사항

- SSH 연결이 끊겨도 Claude Code 세션이 유지되어야 함
- 맥북이 잠자기에 들어가면 안 됨

### tmux

터미널 멀티플렉서. SSH 연결과 독립적으로 세션을 유지한다.

- 여러 Claude 세션을 window로 분리하여 동시 운영 가능
- 연결이 끊겨도 `tmux attach`로 복구
- screen과 비교해 현대적이고 기능이 풍부

### caffeinate

macOS 내장 잠자기 방지 유틸리티.

- `-s` 옵션: 전원 연결 시 시스템 잠자기 방지
- `-d` 옵션: 디스플레이 잠자기 방지
- `-i` 옵션: idle sleep 방지
- `-t N`: N초 후 자동 종료

### 조합 방식

```bash
tmux new-session -s claude 'caffeinate -s -- zsh'
```

caffeinate가 zsh를 감싸서 실행하므로:
- tmux 세션이 살아 있는 동안 caffeinate도 실행
- tmux 세션 종료 시 caffeinate도 자동 종료
- 별도로 caffeinate를 관리할 필요 없음

### 주의사항

- 회사 MDM이 자동 로그아웃을 강제하면, 로그아웃 시 tmux 세션도 종료될 수 있음. 시스템 설정 → 개인 정보 보호 및 보안 → 고급에서 확인 필요
- `caffeinate -s`는 전원 연결 상태에서만 동작. 배터리 모드에서는 `-i`를 사용

---

## 4. 원격 접속: SSH vs mosh

### SSH

- macOS 내장, 별도 설치 불필요
- TCP 기반, 연결 지향적
- 네트워크 전환(와이파이 ↔ 셀룰러) 시 연결 끊김
- IP 변경 시 재접속 필요

### mosh (선택사항)

- UDP 기반, 연결 상태 개념 없음
- 네트워크 전환, IP 변경 시에도 자동 복구
- 오랜 시간 끊겨 있다가 재연결해도 세션 유지
- 로컬 에코로 고지연 환경에서도 타이핑 즉시 반응
- 서버(맥북)와 클라이언트(폰) 양쪽에 설치 필요

### 비교

| 상황 | SSH | mosh |
|------|-----|------|
| 네트워크 전환 | 끊김 → 재접속 + tmux attach | 자동 복구 |
| 장시간 미사용 후 복귀 | 끊김 → 재접속 + tmux attach | 자동 복구 |
| 고지연 환경 | 타이핑 지연 | 로컬 에코로 즉시 반응 |
| 설치 | 불필요 | `brew install mosh` + Termius 설정 |

### 현재 구성에서의 mosh

개인 서버 경유 방식에서는 mosh를 사용할 수 있다. 폰에서 서버까지 mosh(UDP)로 접속하고, 서버에서 맥북까지는 SSH 리버스 터널(TCP)을 사용한다. mosh의 네트워크 전환 대응 이점은 폰-서버 구간에서 발휘되므로 핵심 요구사항을 충족한다.

---

## 5. 모바일 클라이언트: Termius

### 선택 이유

- iOS/Android 모두 지원
- SSH와 mosh 모두 기본 지원 (호스트 설정에서 토글)
- 자동 재연결 기능 내장
- 참고한 블로그(Claude Code On-The-Go)에서도 사용

### 대안

- Blink Shell (iOS): mosh 지원 우수하나 유료
- JuiceSSH (Android): 무료, mosh 미지원
- iSH (iOS): 리눅스 에뮬레이터, SSH/mosh 직접 실행 가능하나 과한 구성

---

## 전체 구성 요약

```
┌─ 맥북 ──────────────────────────────┐
│                                      │
│  tmux (caffeinate -s로 잠자기 방지)  │
│  ├─ Claude Code 세션들               │
│  └─ Claude 훅 → curl ntfy.sh        │
│                                      │
│  autossh (리버스 터널, launchd)      │
│  └─ -R 2222:localhost:22 → 서버     │
└──────────────────────────────────────┘
        │                    │
        │ SSH 리버스 터널     │ HTTPS
        ▼                    ▼
┌─ 개인 서버 ────┐     ntfy.sh 서버
│                 │          │
│  claude 유저    │          │ APNs/FCM
│  (프록시 전용)  │          ▼
│  :2222→맥북:22 │   ┌─ 스마트폰 ─────┐
└─────────────────┘   │                 │
        ▲              │  Ntfy 앱       │
        │ mosh (UDP)   │  Termius       │
        │              │                │
        └──────────────┘                │
                       └─────────────────┘
```

## 참고 자료

- [Claude Code On-The-Go](https://granda.org/en/2026/01/02/claude-code-on-the-go/) — 원본 블로그
- [autossh](https://www.harding.motd.ca/autossh/) — SSH 리버스 터널 자동 유지
- [mosh](https://mosh.org/) — UDP 기반 원격 접속
- [ntfy 문서](https://docs.ntfy.sh/) — 알림 서비스
- [ntfy Rate Limiting](https://docs.ntfy.sh/config/#rate-limiting) — Rate limit 상세
