# DDR5 구현 감사 및 DDR6 문장별 검토 자료

2026-10-21까지 작성한 보고서·체크리스트·분석 스크립트·검증 기록을 보관한 저장소입니다. 원본 입력 파일과 감사 대상 RTL도 함께 포함합니다.

## 결과 파일

| 자료 | 파일 |
| --- | --- |
| DDR5 판정 방법 설명과 정정 사항 | [DDR5_methodology_explained.html](ddr5_audit/deliverables/DDR5_methodology_explained.html) |
| DDR5 브라우저용 보고서 | [DDR5_report_browser.zip](ddr5_audit/deliverables/DDR5_report_browser.zip) |
| DDR5 PDF 내장 전체 보고서 | [JESD79-5B_ddr5_sentence_audit.html](ddr5_audit/deliverables/JESD79-5B_ddr5_sentence_audit.html) |
| DDR5 판정 데이터 | [audit-data.json](ddr5_audit/deliverables/audit-data.json) |
| DDR6 전체 문장별 체크리스트 | [DDR6_sentence_checklist.json](ddr6_review/deliverables/DDR6_sentence_checklist.json) |
| DDR6 장별 JSON·원문 원장·설명서 묶음 | [DDR6_checklist_bundle.zip](ddr6_review/deliverables/DDR6_checklist_bundle.zip) |
| DDR6 작은 요약 파일 | [DDR6_checklist_summary.json](ddr6_review/deliverables/DDR6_checklist_summary.json) |
| DDR6 MRR 검토 예시 | [DDR6_MRR_example.json](ddr6_review/deliverables/DDR6_MRR_example.json) |
| DDR6 장별 분할본 | [chapters](ddr6_review/deliverables/chapters/) |

GitHub는 HTML을 애플리케이션으로 실행하지 않으며 큰 JSON은 미리보기가 제한될 수 있습니다. 파일이나 ZIP을 다운로드한 뒤 HTML은 Chrome/Edge에서, JSON은 편집기에서 여세요. DDR5 브라우저용 ZIP은 압축을 풀고 HTML과 PDF를 같은 폴더에 둡니다.

## 결과를 해석할 때

**DDR5는 정적 규칙 기반 감사의 작업판입니다.** 전 규격에 대한 확정된 준수율이나 모든 문장의 실행 검증을 의미하지 않습니다. 최초 집계와 보고서는 당시 결과를 보존했습니다. 이후 재확인에서 MR31 read-training의 CRC-off 검사에 관한 기존 설명이 잘못되었음을 발견했습니다. `ddr5_device.sv`에는 해당 CRC enable 검사와 진단 호출이 존재합니다. 최신 방법론 설명 HTML의 정정 메모를 함께 읽어야 하며, 최초 집계 수치를 정정 완료된 최종 구현률로 해석해서는 안 됩니다.

**DDR6는 구현 판정용 체크리스트입니다.** 527쪽에서 문장 후보 3,442개를 추출했으며, 단편·초안 메모를 포함한 체크리스트 record는 3,825개입니다. 표/그림 격자의 4,612개 행도 보존합니다. 자동 생성 항목과 원문 대조 예시를 구분했고, 문장 경계·참조·색상·취소선·TBD 검토가 필요한 항목을 표시했습니다. 대응 RTL이 제공되지 않았으므로 구현 상태는 모두 `not_assessed_no_rtl`, 구현률은 `null`입니다.

DDR6 문서는 PROPOSED 초안입니다. 표지에 명시된 검정/빨강/회색 구분 및 취소선 후보를 보존하며, 자동 생성 체크리스트가 확정 표준이나 전체 문장 의미 검토 완료를 뜻하지 않습니다.

## 구성

- `inputs/`: 사용자 제공 DDR5 PDF, 원본 RTL ZIP, DDR6 PDF. `manifest.json`에 SHA-256과 원본 파일명을 기록했습니다.
- `ddr5_audit/`: 추출·판정 데이터, HTML 생성 코드, 규칙, 독립 검증 testbench, 원본 ZIP의 추출본, 과거 검증 로그.
- `ddr6_review/`: 추출·체크리스트 생성·검증 코드, 중간 데이터, JSON Schema, 장별 JSON, 원문 line 원장.
- `SNAPSHOT.sha256`: 이번 저장소 스냅샷의 파일 해시. 하위 폴더의 기존 manifest/ZIP은 해당 시점의 패키지를 기록합니다.

설치된 가상환경, 패키지 캐시 및 컴파일 중간 산출물은 제외했습니다. 기존 로그의 `/workspace/...` 경로는 당시 실행 위치입니다. 저장소 복사본에서는 DDR6 PDF 경로와 DDR5 브라우저 보고서의 PDF 탐색을 상대 경로로 사용할 수 있게 조정했습니다. 기존 결과 파일과 판정은 변경하지 않았습니다.

## 재현 및 조회

Python 3.12 기준입니다. 결과 파일을 열거나 JSON을 조회하는 데는 재생성이 필요하지 않습니다.

```bash
python -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt

# 기존 DDR6 결과 조회
python ddr6_review/deliverables/query_checklist.py --section 7.8.1
python ddr6_review/deliverables/query_checklist.py --text 'command burst length'

# 기존 추출 결과로 DDR6 체크리스트 재생성 및 검증
python ddr6_review/build_checklist.py
python ddr6_review/validate_and_package.py

# DDR5 기존 판정·검증 기록으로 HTML 재생성
python ddr5_audit/build_report.py --pdf inputs/JESD79-5B_v1-2.pdf --zip inputs/rmc-ddr5-main.zip
python ddr5_audit/build_browser_report.py
```

전체 PDF를 다시 추출하려면 다음 명령을 사용합니다. 재생성은 중간 파일과 결과 파일을 덮어쓰므로 기존 결과와의 차이를 확인하세요. PyMuPDF 버전·문장 분할 변경으로 ID가 바뀌면 기존 개별 판정 override를 그대로 재사용하지 않아야 합니다.

```bash
python ddr6_review/extract_ddr6.py
python ddr5_audit/extract_standard.py --pdf inputs/JESD79-5B_v1-2.pdf
```

DDR5 simulator/HTML 검증 재실행에는 `requirements-validation.txt`와 C++20 compiler, make, Chromium이 추가로 필요합니다. `run_tests.py`와 `run_independent.py`가 당시 사용한 Verilator 옵션을 담고 있습니다. 독립 검증의 `SPEC_FAIL`은 실제 불일치 관측이며, 프로그램 exit=0을 규격 통과로 해석하면 안 됩니다. 상세 내용은 [DDR5 설명서](ddr5_audit/README_ko.md)와 [DDR6 설명서](ddr6_review/deliverables/README_ko.md)를 참조하세요.
