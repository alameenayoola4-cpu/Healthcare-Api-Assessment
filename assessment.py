import argparse
import json
import os
import random
import sys
import time
from pathlib import Path
from typing import Any
from typing import Iterable
from typing import Optional
from urllib import error
from urllib import parse
from urllib import request


BASE_URL = "https://assessment.ksensetech.com/api"
DEFAULT_API_KEY = os.environ.get("DEMOMED_API_KEY")
OUTPUT_PATH = Path(__file__).with_name("assessment_results.json")
DOTENV_PATH = Path(__file__).with_name(".env")
DEFAULT_LIMIT = 20
MAX_RETRIES = 6
MAX_PAGES = 50
HIGH_RISK_THRESHOLD = 4


class ApiClient:
    def __init__(self, api_key: str, base_url: str = BASE_URL) -> None:
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")

    def get_json(
        self,
        path: str,
        params: Optional[dict[str, Any]] = None,
        max_retries: int = MAX_RETRIES,
    ) -> dict[str, Any]:
        return self._request_json("GET", path, params=params, max_retries=max_retries)

    def post_json(
        self,
        path: str,
        payload: dict[str, Any],
        max_retries: int = MAX_RETRIES,
    ) -> dict[str, Any]:
        return self._request_json("POST", path, payload=payload, max_retries=max_retries)

    def _request_json(
        self,
        method: str,
        path: str,
        params: Optional[dict[str, Any]] = None,
        payload: Optional[dict[str, Any]] = None,
        max_retries: int = MAX_RETRIES,
    ) -> dict[str, Any]:
        last_error: Optional[Exception] = None

        for attempt in range(1, max_retries + 1):
            url = f"{self.base_url}{path}"
            if params:
                query = parse.urlencode(params)
                url = f"{url}?{query}"

            data = None
            headers = {
                "x-api-key": self.api_key,
                "Accept": "application/json",
            }

            if payload is not None:
                data = json.dumps(payload).encode("utf-8")
                headers["Content-Type"] = "application/json"

            req = request.Request(url=url, data=data, headers=headers, method=method)

            try:
                with request.urlopen(req, timeout=20) as response:
                    body = response.read().decode("utf-8")
                    if not body.strip():
                        return {}
                    return json.loads(body)
            except error.HTTPError as exc:
                body_text = exc.read().decode("utf-8", errors="replace")
                if exc.code in {429, 500, 502, 503, 504} and attempt < max_retries:
                    delay = _retry_delay(attempt, retry_after=exc.headers.get("Retry-After"))
                    time.sleep(delay)
                    continue
                last_error = RuntimeError(
                    f"HTTP {exc.code} for {method} {url}: {body_text}"
                )
            except (error.URLError, TimeoutError, json.JSONDecodeError) as exc:
                if attempt < max_retries:
                    time.sleep(_retry_delay(attempt))
                    continue
                last_error = exc

            break

        if last_error is None:
            raise RuntimeError(f"Failed to complete {method} {path} for an unknown reason")
        raise last_error


def _retry_delay(attempt: int, retry_after: Optional[str] = None) -> float:
    if retry_after:
        try:
            return max(float(retry_after), 0.0)
        except ValueError:
            pass
    return min(1.0 * (2 ** (attempt - 1)) + random.uniform(0.0, 0.25), 8.0)


def load_dotenv_api_key(path: Path = DOTENV_PATH) -> Optional[str]:
    if not path.exists():
        return None

    for line in path.read_text(encoding="utf-8").splitlines():
        text = line.strip()
        if not text or text.startswith("#") or "=" not in text:
            continue
        key, value = text.split("=", 1)
        if key.strip() != "DEMOMED_API_KEY":
            continue
        cleaned = value.strip().strip("'\"")
        return cleaned or None
    return None


def fetch_all_patients(client: ApiClient, limit: int = DEFAULT_LIMIT) -> list[dict[str, Any]]:
    patients: list[dict[str, Any]] = []
    page = 1
    seen_ids: set[str] = set()

    while page <= MAX_PAGES:
        response = client.get_json("/patients", params={"page": page, "limit": limit})
        page_items = _extract_patients(response)
        if not page_items:
            break

        added = 0
        for patient in page_items:
            patient_id = _safe_string(patient.get("patient_id"))
            unique_key = patient_id or json.dumps(patient, sort_keys=True, default=str)
            if unique_key in seen_ids:
                continue
            seen_ids.add(unique_key)
            patients.append(patient)
            added += 1

        pagination = response.get("pagination") if isinstance(response, dict) else None
        has_next = _pagination_has_next(pagination, page=page, added=added, limit=limit)
        total_pages = None
        if isinstance(pagination, dict):
            total_pages = _parse_int(pagination.get("totalPages"))

        if (total_pages is not None and page >= total_pages) or (not has_next and len(page_items) < limit):
            break
        page += 1

    return patients


def _extract_patients(response: Any) -> list[dict[str, Any]]:
    if isinstance(response, dict):
        data = response.get("data")
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict)]
        if isinstance(data, dict):
            inner = data.get("patients")
            if isinstance(inner, list):
                return [item for item in inner if isinstance(item, dict)]
    if isinstance(response, list):
        return [item for item in response if isinstance(item, dict)]
    return []


def _pagination_has_next(pagination: Any, page: int, added: int, limit: int) -> bool:
    if isinstance(pagination, dict):
        if isinstance(pagination.get("hasNext"), bool):
            return pagination["hasNext"]
        total_pages = _parse_int(pagination.get("totalPages"))
        if total_pages is not None:
            return page < total_pages
        total = _parse_int(pagination.get("total"))
        if total is not None:
            return page * limit < total
    return added > 0 and added >= limit


def assess_patients(patients: Iterable[dict[str, Any]]) -> dict[str, list[str]]:
    high_risk_patients: list[str] = []
    fever_patients: list[str] = []
    data_quality_issues: list[str] = []

    for patient in patients:
        patient_id = _safe_string(patient.get("patient_id"))
        if not patient_id:
            continue

        bp_score, bp_invalid = score_blood_pressure(patient.get("blood_pressure"))
        temp_score, temp_invalid, has_fever = score_temperature(patient.get("temperature"))
        age_score, age_invalid = score_age(patient.get("age"))

        total_risk = bp_score + temp_score + age_score

        if total_risk >= HIGH_RISK_THRESHOLD:
            high_risk_patients.append(patient_id)
        if has_fever:
            fever_patients.append(patient_id)
        if bp_invalid or temp_invalid or age_invalid:
            data_quality_issues.append(patient_id)

    return {
        "high_risk_patients": sorted(set(high_risk_patients)),
        "fever_patients": sorted(set(fever_patients)),
        "data_quality_issues": sorted(set(data_quality_issues)),
    }


def score_blood_pressure(value: Any) -> tuple[int, bool]:
    text = _safe_string(value)
    if not text or "/" not in text:
        return 0, True

    systolic_raw, diastolic_raw = text.split("/", 1)
    systolic = _parse_int(systolic_raw)
    diastolic = _parse_int(diastolic_raw)

    if systolic is None or diastolic is None:
        return 0, True

    systolic_stage = 0
    if systolic >= 140:
        systolic_stage = 3
    elif systolic >= 130:
        systolic_stage = 2
    elif systolic >= 120:
        systolic_stage = 1

    diastolic_stage = 0
    if diastolic >= 90:
        diastolic_stage = 3
    elif diastolic >= 80:
        diastolic_stage = 2

    return max(systolic_stage, diastolic_stage), False


def score_temperature(value: Any) -> tuple[int, bool, bool]:
    temp = _parse_float(value)
    if temp is None:
        return 0, True, False
    if temp >= 101.0:
        return 2, False, True
    if temp >= 99.6:
        return 1, False, True
    return 0, False, False


def score_age(value: Any) -> tuple[int, bool]:
    age = _parse_float(value)
    if age is None:
        return 0, True
    if age < 40:
        return 0, False
    if age > 65:
        return 2, False
    return 1, False


def _safe_string(value: Any) -> Optional[str]:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _parse_int(value: Any) -> Optional[int]:
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        if value.is_integer():
            return int(value)
        return None

    text = str(value).strip()
    if not text:
        return None
    try:
        number = float(text)
    except ValueError:
        return None
    if number.is_integer():
        return int(number)
    return None


def _parse_float(value: Any) -> Optional[float]:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)

    text = str(value).strip()
    if not text:
        return None

    try:
        return float(text)
    except ValueError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description="DemoMed Healthcare API assessment client")
    parser.add_argument("--api-key", default=DEFAULT_API_KEY, help="API key for the assessment")
    parser.add_argument(
        "--submit",
        action="store_true",
        help="Submit the generated alert lists to the assessment endpoint",
    )
    args = parser.parse_args()

    if not args.api_key:
        args.api_key = load_dotenv_api_key()

    if not args.api_key:
        raise RuntimeError(
            "API key is required. Pass --api-key, set DEMOMED_API_KEY, or add DEMOMED_API_KEY to .env."
        )

    client = ApiClient(api_key=args.api_key)
    patients = fetch_all_patients(client)
    if not patients:
        raise RuntimeError("No patient data was returned by the API")

    results = assess_patients(patients)
    OUTPUT_PATH.write_text(json.dumps(results, indent=2), encoding="utf-8")

    print(f"Fetched {len(patients)} unique patients")
    print(json.dumps(results, indent=2))
    print(f"Saved alert lists to {OUTPUT_PATH}")

    if args.submit:
        submission_response = client.post_json("/submit-assessment", payload=results)
        print("Submission response:")
        print(json.dumps(submission_response, indent=2))

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1)
