# DDR6 문장별 구현 판정 체크리스트

요청하신 `.Jason`은 표준 JSON(`.json`, UTF-8)으로 작성했습니다.
이 자료는 **무엇을 확인해야 하는지**를 정리한 검토용 자료입니다. DDR6 RTL이 제공되지 않아 실제 구현 여부나 구현률은 산출하지 않았습니다.

- 원본: TG423_1^20260914^1905.99A^Micron^DDR6_Standard_Draft_Rev0.x_R0(1).pdf
- SHA-256: `f4d3758dab5a2e6200d6cfe006ddf41f75ee5576759fbdc035e9935eced54b6a`
- 527쪽, 17개 chapter, 544개 번호 절
- 문장 후보 3,442개(표지/목차/이력 문장 포함), 추가 절·단편 후보 92개, 초안 상태 메모 291개
- 체크리스트 record 총 3,825개
- 표/그림 격자 781개, 보조 행 4,612개
- 원문을 대조해 구체화한 예시 record 24개; 나머지 3,801개는 자동 생성 후 문장별 의미 검토가 필요한 체크리스트입니다.

## 파일

`DDR6_sentence_checklist.json`: 전체 자료. `chapters[].records[]`가 문장/후보 단위입니다.

`chapters/DDR6_chapter_07.json` 등: 장별 분할본. 전체 파일의 부분집합이므로 합쳐서 중복 합산하지 마세요.

`DDR6_checklist_summary.json`: 집계, 공통 8단계, 규칙, 기능별 체크 템플릿, 확인된 초안 문제.

`DDR6_MRR_example.json`: MRR BL24의 8단계 검토 예시와 관련 문장들.

`DDR6_source_ledger.json`: 원문 line, 위치, 색상/취소선 후보, 제외 사유, 나머지 fragment. 전체 JSON의 source_line_ids로 연결합니다.

`DDR6_checklist.schema.json`: 전체 JSON의 구조/미평가 상태 검증용 JSON Schema.

`query_checklist.py`: section/text/id로 문장 조회. 표준 Python만 필요합니다.

## 각 문장 읽는 순서

1. `source`: 원문, PDF 실제 페이지(1부터), 본문 계산 페이지, 위치, 표 행/셀.
2. `draft`와 `open_issues`: 빨강·회색·취소선, TBD, 임시 번호, 문장 경계 등을 먼저 확인합니다. 자동 취소선 제거 문자열은 확정 원문이 아닙니다.
3. `parsed_candidates`, `scope`, `applicability_questions_ko`: 조건/주체/값/모드 후보를 확정합니다. 숫자에는 주소·표 번호도 섞여 있습니다.
4. `checks`와 `verification_plan`: 코드 경로·관측 결과·경계·조합·반례를 구체화합니다. 관련 기능의 체크 템플릿 전체가 그 한 문장의 의무라는 뜻은 아닙니다.
5. `dependency_review`: 명시적 참조, 인접 문장, 의미상 관련 절을 확인합니다. 번호가 존재하는 것과 내용이 맞는 것은 별개입니다.
6. `provenance`: 규칙 매칭과 의미 검토 수준을 확인합니다. 모든 문장에 독립적인 추론/수동 검토를 했다고 표시하지 않습니다.
7. `assessment.evidence`: 향후 RTL revision/file/line, test/assertion, waveform, 실제/기대 결과, 적용 구성과 반례를 입력합니다.

모든 구현 상태는 `not_assessed_no_rtl`, `verdict: null`입니다. 구현률은 `null`이며 0%가 아닙니다.

## 자동 추출의 범위

모든 527쪽의 native text line을 원장에 보존했습니다. 유효 비어있지 않은 line 47,991개가 문장/표/fragment/heading에 배정되었으며 배정 누락은 0개입니다. 이 수치는 **문장 분할과 의미 해석 정확도 100%**를 뜻하지 않습니다.

OCR 및 모든 diagram의 화살표·도형·shading 의미 전사는 수행하지 않았습니다. 문장 경계, cross-page 연결, 표 병합 셀, superscript/수식과 개정 표시는 원본 PDF로 확인해야 합니다. 단편 후보도 남겼으므로 경계 오류가 있어도 원문을 역추적할 수 있습니다. 문장/표/fragment를 중복 합산하지 마세요.

표지의 검정=기통과, 빨강=투표 대상, 회색=DDR5/LPDDR6 참고 범례를 보존했습니다. 취소선 후보는 vector 선 위치로 탐지했습니다. 문서 자체는 PROPOSED draft이며 요구사항 채택 범위를 먼저 결정해야 합니다.

확인된 문제에는 MRR 임시 표/절 번호, CRC의 존재하지 않는 참조 번호, EVEN(25.6)=28 예제 불일치, 붙어서 추출되는 이전/신규 MR 주소, unballoted 절, WUCS 잠정 값이 포함됩니다.

## 조회 예

```bash
python query_checklist.py --section 7.8.1
python query_checklist.py --text 'command burst length'
python query_checklist.py --id D6-P339-0004 --full
```

앱에서 큰 JSON 미리보기가 실패하면 ZIP을 다운로드하여 압축을 푼 뒤 VS Code 등으로 장별 파일을 여세요. 원본 PDF는 이 ZIP에 중복 포함하지 않았습니다.
