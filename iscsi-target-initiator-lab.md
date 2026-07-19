# iSCSI Target/Initiator 구축 실습 (Rocky Linux 10)

📅 실습일: 2026-07-19
🔗 관련 세션: [Rocky 10 DNS/DHCP 구축 실습](./rocky10-dns-dhcp-lab-note.md)
🖥️ 환경: rocky-node1(Target 역할) ↔ rocky-node2(Initiator 역할), Host-only `192.168.56.0/24`

> LIO(`targetcli`) 기반으로 iSCSI Target을 구성하고, 다른 노드에서 네트워크로 그 스토리지를 마운트해보는 실습. SAN(Storage Area Network)의 축소판 개념 실습.

---

## 목차

- [개념 요약](#개념-요약)
- [1. Target 구축 (node1)](#1-target-구축-node1)
- [2. Initiator 접속 (node2)](#2-initiator-접속-node2)
- [3. 마운트 및 사용 테스트](#3-마운트-및-사용-테스트)
- [4. 트러블슈팅 로그](#4-트러블슈팅-로그)
- [5. 다음 실습 아이디어](#5-다음-실습-아이디어)

---

## 개념 요약

| 용어 | 의미 |
|---|---|
| Target | 스토리지를 네트워크에 제공하는 서버 (여기서는 node1) |
| Initiator | 그 스토리지를 사용하는 클라이언트 (여기서는 node2) |
| IQN | iSCSI Qualified Name — `iqn.YYYY-MM.역순도메인:식별자` 형식의 고유 이름 |
| LUN | Logical Unit Number — target이 노출하는 실제 디스크 단위 |
| Portal | target이 iSCSI 요청을 듣는 IP:Port (기본 3260) |
| backstore | 실제 저장 공간의 원천. `fileio`(파일 기반) 또는 `block`(실제 블록 디바이스) |

**iSCSI vs NFS/SMB**: iSCSI는 **블록 단위** 공유(마치 로컬 디스크처럼 파티션·포맷 가능), NFS/SMB는 **파일 단위** 공유. 이 차이가 SAN vs NAS를 가르는 핵심.

---

## 1. Target 구축 (node1)

### 1-1. 패키지 설치

```bash
sudo dnf install -y targetcli
sudo systemctl enable --now target
```

### 1-2. backstore 생성 (fileio 방식 — 별도 디스크 없이 실습 가능)

```bash
sudo targetcli
```

```
/backstores/fileio create name=test_file file_or_dev=/root/fileA size=1G
```

> ⚠️ `size=` 파라미터를 빠뜨리면 `Attempting to create file for new fileio backstore, need a size`에서 멈춘다. 반드시 크기 지정.

> 참고: `block` 방식(`/backstores/block create name=test_block dev=/dev/sdb`)을 쓰려면 VirtualBox에서 VM에 두 번째 디스크를 실제로 추가해야 함. 없으면 `Could not open /dev/sdb` 에러.

### 1-3. iSCSI target(IQN) 생성

```
/iscsi create iqn.2026-07.kt.co.nobreak:server
```

> IQN 형식 주의: `iqn.YYYY-MM.역순도메인:식별자`. **연-월 사이는 반드시 하이픈(`-`)**, 점(`.`)을 쓰면 `WWN not valid as: iqn, naa, eui` 에러 발생.

### 1-4. Portal 확인/생성

```
/iscsi/iqn.2026-07.kt.co.nobreak:server/tpg1/portals ls
```

기본적으로 `0.0.0.0:3260`이 자동 생성되어 있는 경우가 많음(모든 인터페이스에서 수신). 없으면:

```
/iscsi/iqn.2026-07.kt.co.nobreak:server/tpg1/portals create 192.168.56.10
```

> Target 자신이 실제로 갖고 있는 IP(`ip -br a`로 확인)가 아니면 `Could not create NetworkPortal in configFS` 에러 발생.

### 1-5. LUN 매핑 (backstore → target 연결)

```
/iscsi/iqn.2026-07.kt.co.nobreak:server/tpg1/luns create /backstores/fileio/test_file
```

### 1-6. ACL 생성 (initiator IQN 등록 — 이 IQN만 접속 허용)

```
/iscsi/iqn.2026-07.kt.co.nobreak:server/tpg1/acls create wwn=iqn.2026-07.kr.co.nobreak:client
```

### 1-7. 저장 및 종료

```
saveconfig
exit
```

### 1-8. 방화벽 오픈 (TCP 3260)

```bash
sudo firewall-cmd --permanent --add-port=3260/tcp
sudo firewall-cmd --reload
```

### 1-9. 전체 구조 확인 (선택)

```bash
sudo targetcli
ls
```

backstore → iscsi → target → tpg1 → acls/luns/portals 트리가 다 잡혀있는지 한눈에 확인 가능.

---

## 2. Initiator 접속 (node2)

### 2-1. 패키지 설치

```bash
sudo dnf install -y iscsi-initiator-utils
sudo systemctl enable --now iscsid
```

### 2-2. Initiator IQN을 target의 ACL과 일치시키기 (필수)

```bash
sudo vim /etc/iscsi/initiatorname.iscsi
```

```
InitiatorName=iqn.2026-07.kr.co.nobreak:client
```

> 기본값은 `iqn.1994-05.com.redhat:<임의문자열>`(RHEL 계열 패키지의 자동 생성 값)로 되어 있음. 이 값이 target ACL에 등록된 값과 **정확히 일치**해야 로그인이 성공함.

```bash
sudo systemctl restart iscsid
```

### 2-3. Target 검색 (Discovery)

```bash
sudo iscsiadm -m discovery -t st -p 192.168.56.10
```

정상 결과:
```
192.168.56.10:3260,1 iqn.2026-07.kt.co.nobreak:server
```

> `sudo` 없이 실행하면 에러 메시지 없이 조용히 빈 결과만 나옴 — 권한 문제로 실패한 것.

### 2-4. 로그인(연결)

```bash
sudo iscsiadm -m node -T iqn.2026-07.kt.co.nobreak:server -p 192.168.56.10 -l
```

### 2-5. 연결 확인

```bash
lsblk
```

새로운 디스크(예: `sdb`)가 나타나면 성공.

```bash
sudo iscsiadm -m session -P 3
```
`iSCSI Connection State: LOGGED IN`, `iSCSI Session State: LOGGED_IN` 확인.

---

## 3. 마운트 및 사용 테스트

```bash
sudo mkdir -p /mnt/iscsi-test
sudo mkfs.xfs /dev/sdb
sudo mount /dev/sdb /mnt/iscsi-test
echo "hello from iscsi over network" | sudo tee /mnt/iscsi-test/test.txt
cat /mnt/iscsi-test/test.txt
df -h /mnt/iscsi-test
```

### 영속성 확인 (로그아웃 후 재로그인해도 데이터 유지되는지)

```bash
sudo umount /mnt/iscsi-test
sudo iscsiadm -m node -T iqn.2026-07.kt.co.nobreak:server -p 192.168.56.10 -u
sudo iscsiadm -m node -T iqn.2026-07.kt.co.nobreak:server -p 192.168.56.10 -l
sudo mkdir -p /mnt/iscsi-test   # 재로그인 시 디렉토리가 사라졌다면 다시 생성
sudo mount /dev/sdb /mnt/iscsi-test
cat /mnt/iscsi-test/test.txt
```

✅ 재접속 후에도 `test.txt` 내용이 그대로 유지됨을 확인 → 진짜 영속 네트워크 스토리지임을 검증.

---

## 4. 트러블슈팅 로그

| 증상 | 원인 | 해결 |
|---|---|---|
| `Could not open /dev/sdb` | block backstore용 실제 디스크가 VM에 없음 | `fileio` 방식으로 전환하거나 VirtualBox에서 디스크 추가 |
| `Attempting to create file for new fileio backstore, need a size` | `size=` 파라미터 누락 | `size=1G` 등 크기 명시 |
| `WWN not valid as: iqn, naa, eui` | IQN에서 연-월 구분을 점(`.`)으로 씀 | `iqn.2026-07...`처럼 하이픈(`-`)으로 수정 |
| `Could not create NetworkPortal in configFS` | portal에 지정한 IP가 서버 자신의 실제 IP가 아니거나, 이미 `0.0.0.0:3260`으로 존재 | `ip -br a`로 실제 IP 확인 후 지정, 또는 기존 portal 목록(`portals ls`) 확인 후 중복 생성 방지 |
| initiator에서 `discovery` 결과가 빈 값 | `sudo` 없이 실행 | `sudo iscsiadm ...`으로 재실행 |
| `mount: /mnt/iscsi-test: mount point does not exist` | 마운트 포인트 디렉토리 미생성(또는 재로그인 후 사라짐) | `sudo mkdir -p /mnt/iscsi-test` 먼저 실행 |

---

## 5. 다음 실습 아이디어

- [ ] **CHAP 인증 추가** — 현재 인증 없이(`username: <empty>`) IQN만 맞으면 접속 가능한 상태. CHAP username/password 설정 후 인증 있는 연결과 비교
- [ ] **tcpdump로 iSCSI 트래픽 캡처** — `sudo tcpdump -i enp0s8 port 3260`로 평문 전송 여부 직접 확인 (보안 관점 학습)
- [ ] **block backstore 실습** — VirtualBox에 두 번째 디스크 추가 후 `/backstores/block`으로 재구성, fileio와 성능/구성 차이 비교
- [ ] **Proxmox 자체 스토리지로 iSCSI 연동** — Proxmox 웹 UI에서 이 target을 스토리지로 등록해보기