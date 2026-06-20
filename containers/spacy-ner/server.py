import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import spacy


MODEL = os.environ.get("SPACY_MODEL", "en_core_web_md")
HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8080"))
EXCLUDE = [
    name
    for name in os.environ.get(
        "SPACY_EXCLUDE",
        "tagger,parser,lemmatizer,attribute_ruler",
    ).split(",")
    if name
]

# Keep only NER-capable components enabled to reduce startup and memory overhead.
NLP = spacy.load(MODEL, exclude=EXCLUDE)


def serialize_doc(doc, labels=None):
    entities = []
    for ent in doc.ents:
        if labels and ent.label_ not in labels:
            continue
        entities.append(
            {
                "text": ent.text,
                "label": ent.label_,
                "start": ent.start_char,
                "end": ent.end_char,
            }
        )
    return entities


class Handler(BaseHTTPRequestHandler):
    server_version = "spacy-ner/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/health", "/healthz"):
            self.send_json(
                200,
                {
                    "status": "ok",
                    "model": MODEL,
                    "pipes": NLP.pipe_names,
                },
            )
            return

        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/entities":
            self.send_json(404, {"error": "not found"})
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length <= 0:
            self.send_json(400, {"error": "request body is required"})
            return

        try:
            payload = json.loads(self.rfile.read(content_length))
        except json.JSONDecodeError:
            self.send_json(400, {"error": "request body must be valid JSON"})
            return

        text = payload.get("text")
        texts = payload.get("texts")
        labels = payload.get("labels") or []

        if text and texts:
            self.send_json(400, {"error": "provide either text or texts, not both"})
            return

        if text is not None:
            if not isinstance(text, str) or not text.strip():
                self.send_json(400, {"error": "text must be a non-empty string"})
                return
            items = [text]
        elif texts is not None:
            if not isinstance(texts, list) or not texts or not all(isinstance(item, str) and item.strip() for item in texts):
                self.send_json(400, {"error": "texts must be a non-empty list of strings"})
                return
            items = texts
        else:
            self.send_json(400, {"error": "request must include text or texts"})
            return

        label_filter = set(labels) if labels else None
        docs = NLP.pipe(items, batch_size=min(max(len(items), 1), 32))
        results = []
        for source_text, doc in zip(items, docs):
            results.append(
                {
                    "text": source_text,
                    "entities": serialize_doc(doc, labels=label_filter),
                }
            )

        self.send_json(
            200,
            {
                "model": MODEL,
                "results": results,
            },
        )


if __name__ == "__main__":
    print(f"Loading model {MODEL} with pipes: {NLP.pipe_names}")
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Listening on {HOST}:{PORT}")
    server.serve_forever()