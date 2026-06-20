import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from email_reply_parser import EmailReplyParser


HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8080"))
MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", "1048576"))


def _fragment_bool(fragment, *names):
    for name in names:
        value = getattr(fragment, name, None)
        if value is not None:
            return bool(value)
    return False


def serialize_fragment(fragment):
    return {
        "content": (getattr(fragment, "content", "") or ""),
        "is_quoted": _fragment_bool(fragment, "quoted", "is_quoted"),
        "is_signature": _fragment_bool(fragment, "signature", "is_signature"),
        "is_hidden": _fragment_bool(fragment, "hidden", "is_hidden"),
    }


def parse_email(email_text):
    message = EmailReplyParser.read(email_text)
    parsed_reply = EmailReplyParser.parse_reply(email_text)
    components = [serialize_fragment(fragment) for fragment in getattr(message, "fragments", [])]

    return {
        "parsed_reply": parsed_reply,
        "components": components,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "email-reply-api/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def error(self, status, code, message):
        self.send_json(
            status,
            {
                "error": {
                    "code": code,
                    "message": message,
                }
            },
        )

    def do_GET(self):
        if self.path in ("/", "/health", "/healthz"):
            self.send_json(
                200,
                {
                    "status": "ok",
                    "service": "email-reply-api",
                },
            )
            return

        self.error(404, "not_found", "Route not found")

    def do_POST(self):
        if self.path != "/parse-reply":
            self.error(404, "not_found", "Route not found")
            return

        content_type = self.headers.get("Content-Type", "")
        if content_type and "application/json" not in content_type:
            self.error(415, "unsupported_media_type", "Content-Type must be application/json")
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length <= 0:
            self.error(400, "invalid_request", "Request body is required")
            return

        if content_length > MAX_BODY_BYTES:
            self.error(413, "payload_too_large", "Request body exceeds MAX_BODY_BYTES")
            return

        try:
            payload = json.loads(self.rfile.read(content_length))
        except json.JSONDecodeError:
            self.error(400, "invalid_json", "Request body must be valid JSON")
            return

        email_text = payload.get("email")
        if email_text is None:
            self.error(400, "invalid_request", "Request body must include email")
            return

        if not isinstance(email_text, str) or not email_text.strip():
            self.error(400, "invalid_request", "email must be a non-empty string")
            return

        result = parse_email(email_text)
        self.send_json(200, result)


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Listening on {HOST}:{PORT}")
    server.serve_forever()
