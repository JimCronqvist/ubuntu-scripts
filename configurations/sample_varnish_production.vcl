vcl 4.1;

import std;
import dynamic;

acl purge {
  # ACL we'll use later to allow purges
  "localhost";
  "127.0.0.1";
  "::1";
}

acl server_status {
  "localhost";
  "127.0.0.1";
  "::1";
}

backend default none;

probe healthcheck {
  .request =
    "HEAD ${BACKEND_HEALTH_ENDPOINT} HTTP/1.1"
    "Host: localhost"
    "Connection: close"
    "User-Agent: Varnish Health Probe";

  # If 3 out of the last 8 polls succeeded the backend is considered healthy, otherwise it will be marked as sick
  .window = 8;      # (default 8); 
  .threshold = 6;   # (default 3);
  .initial = 5;     # (default one less than .threshold);
  .interval = 5s;   # check the health of each backend every 5 seconds (default 5s).
  .timeout = 10s;   # timing out after 10 seconds (default 2s).
}

sub vcl_init {
  new d = dynamic.director(
    probe = healthcheck,
    # max_connections       = 300,    # Maximum number of concurrent connections to the backend
    # first_byte_timeout    = 300s,   # How long to wait before we receive a first byte from our backend?
    # connect_timeout       = 5s,     # How long to wait for a backend connection?
    # between_bytes_timeout = 2s,     # How long to wait between bytes received from our backend?
    ttl = 30s                         # How long to cache the backend lookup
  );
}

sub vcl_recv {
  set req.http.host = "${BACKEND_HOST}";
  set req.backend_hint = d.backend(req.http.host, "${BACKEND_PORT}");

  # Remove the proxy header (see https://httpoxy.org/#mitigate-varnish)
  unset req.http.proxy;

  # Remove the x-cache header we will set later
  unset req.http.x-cache;

  # Normalize the query arguments
  set req.url = std.querysort(req.url);

  # Allow purging
  if (req.method == "PURGE") {
    if (!client.ip ~ purge) {
	    return (synth(405, "This IP is not allowed to send PURGE requests."));
    }
    return (purge);
  }
  
  # Allow banning
  if (req.method == "BAN") {
    if (!client.ip ~ purge) {
      return (synth(405, "This IP is not allowed to send BAN requests."));
    }
    ban(req.http.x-ban);
    return(synth(200, "Ban added"));
  }
  
  # Allow visiting the server-status page
  if (req.url ~ "^/server-status" && !client.ip ~ server_status) {
    return (synth(405, "This IP is not allowed to visit the server-status page."));
  }

  if (req.url ~ "/varnish/health"){
    set req.http.Connection = "close";
    return (synth(200, "OK"));
  }

  call vcl_req_host;   # Host presence check for http/1.1 requests and lower casing the host header
  call vcl_req_method; # Pipe unknown http methods and only allow cache for GET and HEAD requests.

  # Implementing websocket support
  if (req.method == "GET" && req.http.Upgrade ~ "(?i)websocket") {
    return (pipe);
  }

  # Some generic URL manipulation
  # First remove the Google Analytics added parameters, useless for our backend
  if (req.url ~ "(\?|&)(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=") {
    set req.url = regsuball(req.url, "&(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "");
    set req.url = regsuball(req.url, "\?(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "?");
    set req.url = regsub(req.url, "\?&", "?");
    set req.url = regsub(req.url, "\?$", "");
  }

  # Strip hash, server doesn't need it.
  if (req.url ~ "\#") {
    set req.url = regsub(req.url, "\#.*$", "");
  }

  # Strip a trailing ? if it exists
  if (req.url ~ "\?$") {
    set req.url = regsub(req.url, "\?$", "");
  }

  # For all domains called cdn.*, assets.* and files.*, remove all cookies.
  if (req.http.cookie && req.http.host ~ "^(cdn|assets|files)\.") {
    unset req.http.cookie;
  }

  # Remove cookies for some extensions on URLs except for the URL exceptions matched.
  if (req.http.cookie && req.url ~ "\.(css|js)(\?(.*))?$") {
    unset req.http.cookie;
  }

  # Remove cookies for cookie free URLs
  if (req.http.cookie && req.url ~ "^/(images|assets|vendor)/") {
    unset req.http.cookie;
  }

  # Unset the entire cookie
  #unset req.http.cookie;

  # Some generic cookie manipulation, don't manipulate empty cookies
  if (req.http.Cookie !~ "^\s*$") {
    # Remove the "has_js" cookie
    set req.http.Cookie = regsuball(req.http.Cookie, "has_js=[^;]+(; )?", "");

    # Remove any Google Analytics based cookies
    set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "_ga=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "_gat=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "utmctr=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "utmcmd.=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "utmccn.=[^;]+(; )?", "");

    # Remove DoubleClick offensive cookies
    set req.http.Cookie = regsuball(req.http.Cookie, "__gads=[^;]+(; )?", "");

    # Remove a ";" prefix in the cookie if present
    set req.http.Cookie = regsuball(req.http.Cookie, "^;\s*", "");
  }

  # Are there cookies left with only spaces or that are empty?
  if (req.http.cookie ~ "^\s*$") {
    unset req.http.cookie;
  }

  # Large static files are delivered directly to the end-user without waiting for Varnish to fully read the file first.
  # Varnish 4 fully supports Streaming, so set do_stream in vcl_backend_response()
  if (req.http.cookie && req.url ~ "^[^?]*\.(7z|avi|bz2|flac|flv|gz|mka|mkv|mov|mp3|mp4|mpeg|mpg|ogg|ogm|opus|rar|tar|tgz|tbz|txz|wav|webm|xz|zip)(\?.*)?$") {
    unset req.http.Cookie;
  }

  # Remove all cookies for static files
  if (req.http.cookie && req.url ~ "^[^?]*\.(7z|avi|bmp|bz2|css|csv|doc|docx|eot|flac|flv|gif|gz|ico|jpeg|jpg|js|less|mka|mkv|mov|mp3|mp4|mpeg|mpg|odt|otf|ogg|ogm|opus|pdf|png|ppt|pptx|rar|rtf|svg|svgz|swf|tar|tbz|tgz|ttf|txt|txz|wav|webm|webp|woff|woff2|xls|xlsx|xml|xz|zip)(\?.*)?$") {
    unset req.http.Cookie;
  }

  # Send Surrogate-Capability headers to announce ESI support to backend
  set req.http.Surrogate-Capability = "key=ESI/1.0";

  call vcl_req_authorization; # Do not cache if we have any Authorization or X-Api-Key headers
  call vcl_req_cookie;        # Do not cache if we have Cookies left

  # Ignore built-in by returning here, as we have already checked for every check that is included as built-in.
  return (hash); 
}

sub vcl_req_authorization {
  if (req.http.X-Api-Key) {
    return (pass); # Not cacheable by default
  }
}

sub vcl_hash {
  if (req.http.Cookie) {
    hash_data(req.http.Cookie);
  }
  if (req.http.X-Forwarded-Proto) {
    hash_data(req.http.X-Forwarded-Proto);
  }
}

sub vcl_pipe {
  set req.http.X-Cache = "pipe uncacheable";
  
  # Implementing websocket support
  if (req.method == "GET" && req.http.upgrade) {
    set bereq.http.upgrade = req.http.upgrade;
    set bereq.http.connection = req.http.connection;
  }
}

sub vcl_miss {
  set req.http.X-Cache = "miss";
}

sub vcl_pass {
  set req.http.x-cache = "pass";
}

# Called when a cache lookup is successful.
sub vcl_hit {
  set req.http.X-Cache = "hit";
  set req.http.X-Cache-Ttl-Remaining = obj.ttl;

  # If a pure hit, deliver it
  if (obj.ttl >= 0s) {
    return (deliver);
  }
  
  # Varnish does request coalescing, give a grace period of 10s for pending requests in the wait queue, and serve 
  # stale content immediately for faster responses, and avoid releasing thousands of requests at the same time. 
  # Read about grace mode here: https://www.varnish-cache.org/docs/trunk/users-guide/vcl-grace.html 
  if (std.healthy(req.backend_hint) && (obj.ttl + 10s > 0s)) {
    # Reduce the thundering herd problem
    set req.http.X-Cache = "hit grace healthy";
    return (deliver);
  } else if (obj.ttl + obj.grace > 0s) {
    # Backend is not healthy, serve stale content
    set req.http.X-Cache = "hit grace unhealthy";
    return (deliver);
  }
}

# Handle the HTTP request coming from our backend
sub vcl_backend_response {
  # Called after the response headers has been successfully retrieved from the backend.

  # Pause ESI request and remove Surrogate-Control header
  if (beresp.http.Surrogate-Control ~ "ESI/1.0") {
    unset beresp.http.Surrogate-Control;
    set beresp.do_esi = true;
  }

  # Don't cache common 50x responses, don't erase it from the cache if we have a stale version
  if (beresp.status == 500 || beresp.status == 502 || beresp.status == 503 || beresp.status == 504) {
    if (bereq.is_bgfetch) {
      return (abandon);
    }
    set beresp.http.X-Uncacheable-Reason = "50x error";
    set beresp.uncacheable = true;
  }
  
  # Enable cache for all static files
  if (bereq.url ~ "^[^?]*\.(7z|avi|bmp|bz2|css|csv|doc|docx|eot|flac|flv|gif|gz|ico|jpeg|jpg|js|less|mka|mkv|mov|mp3|mp4|mpeg|mpg|odt|otf|ogg|ogm|opus|pdf|png|ppt|pptx|rar|rtf|svg|svgz|swf|tar|tbz|tgz|ttf|txt|txz|wav|webm|webp|woff|woff2|xls|xlsx|xml|xz|zip)(\?.*)?$") {
    unset beresp.http.set-cookie;
  }
  
  # Large static files are delivered directly to the end-user without waiting for Varnish to fully read the file first.
  # Varnish 4 fully supports Streaming, so use streaming here to avoid locking.
  if (bereq.url ~ "^[^?]*\.(7z|avi|bz2|flac|flv|gz|mka|mkv|mov|mp3|mp4|mpeg|mpg|ogg|ogm|opus|rar|tar|tgz|tbz|txz|wav|webm|xz|zip)(\?.*)?$") {
    unset beresp.http.set-cookie;
    set beresp.do_stream = true;  # Check memory usage it'll grow in fetch_chunksize blocks (128k by default) if the backend doesn't send a Content-Length header, so only enable it for big objects
  }
  
  
  # Custom checks to determine if the object is uncacheable - marked as Hit-for-Miss and returns
  
  ## Don't cache requests with no cache headers defined (Cache-Control, Expires, ETag or Last-Modified), should fall back on "no-cache"
  if (!beresp.http.Cache-Control && !beresp.http.Expires && !beresp.http.ETag && !beresp.http.Last-Modified) {
    set beresp.http.X-Uncacheable-Reason = "no cache headers";
    call vcl_beresp_hitmiss;
  }
  
  # Built-in Varnish checks to determine if the object is uncacheable - marked as Hit-for-Miss and returns
  call vcl_builtin_backend_response;

  # Passed all checks, the object is determined as cacheable
  set beresp.http.X-Cacheable = "yes";
  
  # Allow stale content, in case the backend goes down. Make Varnish keep all objects for 6 hours beyond their TTL.
  set beresp.grace = 6h;
  
  return (deliver);
}

sub vcl_builtin_backend_response {
  if (bereq.uncacheable) {
    set beresp.http.X-Uncacheable-Reason = "uncacheable";
  }
}

sub vcl_beresp_stale {
  if (beresp.ttl <= 0s) {
    set beresp.http.X-Uncacheable-Reason = "ttl <= 0s";
  }
}

sub vcl_beresp_cookie {
  if (beresp.http.Set-Cookie) {
    set beresp.http.X-Uncacheable-Reason = "set-cookie";
  }
}

sub vcl_beresp_control {
  if (beresp.http.Cache-Control ~ "(?i:no-cache|no-store|private)") {
    set beresp.http.X-Uncacheable-Reason = "cache-control";
  }
}

sub vcl_beresp_vary {
  if (beresp.http.Vary == "*") {
    set beresp.http.X-Uncacheable-Reason = "vary";
  }
}

sub vcl_beresp_hitmiss {
  set beresp.http.X-Cacheable = "no";
}

# The routine when we deliver the HTTP request to the client
sub vcl_deliver {
  if (obj.uncacheable) {
    set req.http.X-Cache = req.http.X-Cache + " uncacheable";
  } else {
    set req.http.X-Cache = req.http.X-Cache + " cached";
  }
  set resp.http.X-Cache = req.http.X-Cache;

  # Please note that obj.hits is not 100% accurate but works for debug purposes, see bug 1492 for details.
  set resp.http.X-Cache-Hits = obj.hits;

  # Add a debug header to see the remaining TTL for the cached object
  if (req.http.X-Cache-Ttl-Remaining) {
    set resp.http.X-Cache-Ttl-Remaining = req.http.X-Cache-Ttl-Remaining;
  }
  
  # Add a debug header to see the remaining cookies after filtering.
  if (req.http.Cookie) {
    set resp.http.X-Cookie-Debug = req.http.Cookie;
  }

  # Remove some headers added by Varnish
  unset resp.http.Via;
  unset resp.http.X-Varnish;
  
  # Remove some debug headers added in this vcl
  #unset resp.http.X-Cache;
  #unset resp.http.X-Cache-Hits;
  #unset resp.http.X-Cache-Ttl-Remaining;
  #unset resp.http.X-Cacheable;
  #unset resp.http.X-Uncacheable-Reason;
  
  return (deliver);
}

sub vcl_synth {
  set req.http.X-Cache = "synth synth";
  set resp.http.X-Cache = req.http.X-Cache;
}

sub vcl_backend_error {
  std.log("built-in rule: generating synthetic response");
  set beresp.http.Content-Type = "text/html; charset=utf-8";
  set beresp.http.Retry-After = "5";
  set beresp.body = {"<!DOCTYPE html>
  <html>
    <head>
	    <meta name="viewport" content="width=device-width"/>
	    <title>"} + beresp.status + " " + beresp.reason + {"</title>
	    <style type="text/css">
		    html  { height: 100%; }
		    body  { font-family: -apple-system, BlinkMacSystemFont, Roboto, 'Segoe UI'; margin: 0; display: flex;  width: 100%; height: 100vh; align-items: center; justify-content: center; font-size: 14px; }
		    h1    { display: inline-block; padding-right: 14px; margin-right: 14px; border-right: 1px solid rgba(0, 0, 0, 0.3); font-size: 24px; font-weight: 500; padding-left: 8px; }
		    small { font-size: x-small; }
	    </style>
	  </head>
	  <body>
  	  <h1>"} + beresp.status + {"</h1>
	    <p>"} + beresp.reason + " <small>(xid " + bereq.xid + ")</small>" + {"</p>
	  </body>
  </html>
  "};
  return (deliver);
}
