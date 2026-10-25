# RGC standard library: https (compatibility layer)
#
# The http module already supports https:// natively (TLS is provided by lib/tls.rg, pure RGC).
# This module keeps the old API and delegates to http internally, so existing code can migrate easily.
#
# Usage:
#   import https
#   r = https.get("https://example.com/")
#   if r.ok {
#       print(r.response.status)
#       print(r.response.body)
#   } else {
#       print("request failed:", r.error)
#   }
#
# Semantics:
#   - Only https:// is supported; http:// returns "not an https URL (use the http module)".
#   - get/post verify the certificate chain and hostname; use get_insecure/post_insecure for self-signed/intranet services.
#   - Redirects, gzip, Cookie, etc. behave like the http module (module-level entries are one-shot connections).
#   - No external TLS library is linked; the handshake and crypto run in RGC.

import http
import string
from http import HttpResult, fail_result

def do_request(method: str, url: str, body: str, has_body: bool,
               verify: bool) -> HttpResult {
    if not string.to_lower(url).startswith("https://") {
        return fail_result("not an https URL (use the http module)")
    }
    c = http.new_client()
    if not verify {
        c.verify_tls = False
    }
    r = fail_result("unreachable")
    if has_body {
        r = c.request(method, url, body)
    } else {
        r = c.get(url)
    }
    c.close()
    return r
}

public def get(url: str) -> HttpResult {
    return do_request("GET", url, "", False, True)
}

public def post(url: str, body: str) -> HttpResult {
    return do_request("POST", url, body, True, True)
}

public def get_insecure(url: str) -> HttpResult {
    return do_request("GET", url, "", False, False)
}

public def post_insecure(url: str, body: str) -> HttpResult {
    return do_request("POST", url, body, True, False)
}
