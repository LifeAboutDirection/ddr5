# JESD79-5B v1.20 ↔ DDR5 SystemVerilog 구현 대조

사용자 제공 PDF 502페이지와 ZIP 안의 `verif/ddr5_model/rtl/ddr5_device.sv` 및 직접 사용하는 3개 package를 기준으로 작성한 **정적 대조 검토판**입니다. 원본 RTL은 수정하지 않았습니다.

`deliverables/JESD79-5B_ddr5_sentence_audit.html`을 브라우저에서 열면 됩니다. 원문 PDF, 코드 전체, 판정 데이터가 HTML에 내장되어 인터넷 연결이 필요 없습니다. 브라우저가 내장 PDF를 표시하지 못하면 보고서의 PDF 저장 버튼으로 원문을 저장할 수 있습니다.

## 주요 결과와 해석

- 추출 문장 후보: 3,507개
- 전체 digital 대상: 2,567개, 구현 확인 F: 204개 → **7.95%**
- device-local 대상만: 2,485개, F: 204개 → **8.21%**
- P 부분 구현 353, N 미구현 1,693, X 규격 불일치 179, U 판정 보류 56, S system 범위 82
- E 아날로그/물리/참조 등 제외 문장: 940개
- 전체 추출 항목: 13,985개. 문장 외 표 행 5,165개, 단편/그림 문구 5,311개, CRC 수식 블록 2개.
- 표 행 중 U 판정 보류 1,036개. 문장과 별도로 표시하며 문장 분모에 섞지 않았습니다.

계산식은 `F/(F+P+N+X+U+S)×100`입니다. P에는 임의의 점수를 부여하지 않습니다. 모든 디지털 항목을 포함해 달라는 요청에 따라 optional 기능, BL32, 3DS, 다른 밀도/속도 및 시스템 측 digital 항목도 포함했습니다. 따라서 특정 제품 구성의 필수 적합성 점수나 개발 공수 달성률과 다릅니다.

**이 수치는 전 규격의 확정된 구현률/준수율이 아닙니다.** 문장 후보 추출·규칙 기반 정적 대조와 개별 검토 결과의 보수적 집계입니다. PDF 문장 경계, 병합 표, 그림에만 있는 조건의 완전한 변환을 보증하지 않으며 모든 문장에 독립 실행 검증을 수행한 것은 아닙니다. 판정 보류와 추출 경고를 원문 페이지와 함께 재검토할 수 있도록 보존했습니다.

## 보고서 사용법

1. 상단 상태 카드나 Chapter-wise 표에서 원하는 범위를 선택합니다.
2. 장·절, 판정, 항목 유형, 검색어를 선택합니다. 기본 목록은 제외 문장까지 표시합니다.
3. 문장을 펼치면 원문, 한국어 판정 사유, 적용 방법, 코드 근거가 나옵니다.
4. 코드 버튼은 원본 파일 전체와 인용 줄을, PDF 버튼은 해당 원문 페이지를 엽니다.
5. 원문 전체 페이지 보기에서 문장이 누락/분리되었는지 교차 확인할 수 있습니다.
6. HTML의 CSV 다운로드는 전체 문장과 브라우저 내 검토 체크 표시를 내보냅니다. 체크 표시는 구현 판정/점수를 바꾸지 않습니다.

## 검증 결과

- 원본 핵심 testbench 5개: build/run 모두 통과. `tb_ecc`, `tb_ddr5_smoke`, `tb_ddr5_refresh`, `tb_ddr5_ecc`, `tb_ddr5_training`.
- 독립 white-box 검사 14개: 14개에서 규격 동작 불일치 또는 checker 누락 재현. reset 기본값, MR 접근, MRR 데이터/CRC, 연속 READ, AP/PRE, byte mask, RFM/REF.
- `DQ_BITS=4`: 음수/0 replication으로 elaboration 실패.
- CRC-8: PDF의 XOR 8식과 source shift algorithm의 영벡터+64개 기저벡터가 일치. 선형 map의 동일성 확인이며 DQ mapping/frame/latency 검증은 별개입니다.
- HTML: Chromium에서 장·절, 상태 필터, 코드, 페이지 텍스트, PDF 연결, CSV 및 모바일 화면을 확인. JS page error 없음.

독립 테스트는 내부 task와 state를 직접 설정합니다. 전체 pin-level 프로토콜 sign-off test가 아닙니다. MRW/MRR bank-idle 사례는 verification model의 불법 명령 진단 누락을 확인합니다. `tb_audit.sv`는 SPEC_FAIL을 출력한 뒤 `$finish`하므로 **프로세스 exit=0을 규격 통과로 해석하면 안 됩니다**.

사용 simulator는 PyPI `verilator` distribution 5.48.0이고 wheel 실행 출력은 Verilator 5.49입니다. C++20과 `CFG_CXXFLAGS_PCH_I=-include` build 설정을 사용했습니다. 이는 저장소에서 주장하는 특정 toolchain 인증을 의미하지 않습니다.

## 포함 파일

- `deliverables/*.html`: 독립 실행 HTML
- `deliverables/audit-data.json`: 판정, 원문 페이지, 표, 코드, 테스트 로그가 포함된 전체 데이터
- `deliverables/sentence-audit.csv`: 모든 문장 후보의 판정과 근거
- `extracted.json`: 판정 전 추출 결과
- `audited.json`: 정적 판정 결과
- `audit_rules.py`, `review_pass2.py`, `finalize_audit.py`: 판정 규칙 및 개별 수정
- `extract_standard.py`, `build_report.py`, `report_template.html`: 추출/보고서 생성
- `run_tests.py`, `run_independent.py`, `verify_crc.py`, `tb_audit.sv`: 실행 검증 재현
- `source/rmc-ddr5-main/verif/ddr5_model/rtl`: 원본 대상과 직접 package의 사본
- `source/rmc-ddr5-main/verif/ddr5_model/tb`: 실행한 원본 testbench 5개
- `validation`: 테스트 로그, 실행 명령/결과, 브라우저 확인 결과/화면
- `MANIFEST.sha256`: ZIP에 포함한 파일의 SHA-256

## 재현

Python 3.12, PyMuPDF, C++20 compiler/make 및 Verilator wheel이 필요합니다. HTML UI 검증에는 Playwright와 Chromium도 필요합니다. PyMuPDF의 버전과 table extraction 결과에 따라 추출 ID/행 구분이 달라질 수 있으므로 동일 판정의 재현은 먼저 포함된 `extracted.json`을 사용하세요. 새로운 PDF 또는 변경된 ID에 기존 개별 override를 그대로 적용하면 안 됩니다.

```bash
python finalize_audit.py
python verify_crc.py
python run_tests.py
python run_independent.py
python build_report.py --pdf /path/to/JESD79-5B_v1-2.pdf --zip /path/to/rmc-ddr5-main.zip
```

`run_tests.py`와 `run_independent.py`는 `tools/bin/python`이 존재하면 이를 사용하고, 없으면 실행한 Python 환경의 `verilator` module을 사용합니다. 원본 PDF와 ZIP은 사용자 업로드 파일을 지정합니다. HTML 안의 PDF도 원본과 동일한 바이트입니다. `build_report.py`는 대상 RTL/package의 ZIP 바이트 동일성, 근거 line 범위, ID/상태 무결성을 검사합니다.

전체 추출을 다시 실행하려면:

```bash
python extract_standard.py --pdf /path/to/JESD79-5B_v1-2.pdf
```

재추출은 `extracted.json`과 중간 파일을 덮어씁니다. 기존 결과를 보존한 별도 디렉터리에서 실행하세요. 본 패키지에는 compiler build 산출물·가상환경은 포함하지 않았습니다.
