from typing import Dict


class ReportSummaryService:
    async def summarize(self, filename: str, content_type: str, raw_text: str | None = None) -> Dict:
        if not raw_text:
            return {"summaryStatus": "UNAVAILABLE", "summary": None}
        return {
            "summaryStatus": "AVAILABLE",
            "summary": {
                "keyObservations": [raw_text[:300]],
                "simplifiedExplanation": "Text was extracted and summarized for readability.",
                "importantTerms": [],
                "disclaimer": "AI-generated summary. Not medical advice.",
                "sourceFilename": filename,
                "contentType": content_type,
            },
        }
