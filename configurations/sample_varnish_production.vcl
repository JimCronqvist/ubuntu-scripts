#
# Based on: https://github.com/mattiasgeniar/varnish-4.0-configuration-templates/blob/master/default.vcl
#
vcl 4.0;

import std;

# Default backend definition. Set this to point to your content server.
backend default {
    .host = "127.0.0.1";
    .port = "8080";
	
    .probe = {
        #.url = "/"; # short easy way (GET /)
        # We prefer to only do a HEAD /
        .request =
            "HEAD / HTTP/1.1"
            "Host: localhost"
            "Connection: close"
            "User-Agent: Varnish Health Probe";

        .interval  = 5s; # check the health of each backend every 5 seconds
        .timeout   = 2s; # timing out after 2 second.
        .window    = 5;  # If 3 out of the last 5 polls succeeded the backend is considered healthy, otherwise it will be marked as sick
        .threshold = 3;
    }
}

acl purgers {
    # ACL we'll use later to allow purges
    "localhost";
    "127.0.0.1";
    "::1";
}

sub vcl_recv {
    # Happens before we check if we have this in cache already.
    #
    # Typically you clean up the request here, removing cookies you don't need,
    # rewriting the request, etc.
    
    
    # Normalize the header, remove the port (in case you're testing this on various TCP ports)
    #set req.http.Host = regsub(req.http.Host, ":[0-9]+", "");

    # Normalize the query arguments
    set req.url = std.querysort(req.url);
	
    # Allow purging
    if (req.method == "PURGE") {
        if (!client.ip ~ purgers) { # purgers is the ACL defined at the beginning
            # Not from an allowed IP? Then die with an error.
            return (synth(405, "This IP is not allowed to send PURGE requests."));
        }
        # If you got this stage (and didn't error out above), purge the cached result
        return (purge);
    }

    # Only deal with "normal" types
    if (req.method != "GET" && 
        req.method != "HEAD" &&
        req.method != "PUT" &&
        req.method != "POST" &&
        req.method != "TRACE" &&
        req.method != "OPTIONS" &&
        req.method != "PATCH" &&
        req.method != "DELETE") {
        /* Non-RFC2616 or CONNECT which is weird. */
        return (pipe);
    }
  
    # Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
    if (req.http.Upgrade ~ "(?i)websocket") {
        return (pipe);
    }

    # Only cache GET or HEAD requests. This makes sure the POST requests are always passed.
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }
	
    # Some generic URL manipulation, useful for all templates that follow
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
    
    # Unset the entire cookie
    #unset req.http.cookie;
    
    # For all domains called cdn.*, assets.* and files.*, remove all cookies.
    if (req.http.cookie && req.http.host ~ "^(cdn|assets|files)\.") {
        unset req.http.cookie;
    }
    
    # Remove cookies for cookie free URLs
    if (req.http.cookie && req.url ~ "^/(images)") {
        unset req.http.cookie;
    }
    
    # Remove cookies for some extensions
    if (req.http.cookie && req.url ~ "\.(css|js)(\?(.*))?$") {
        unset req.http.cookie;
    }
    
    # Cookie manipulation/sanitiation
    if (req.http.cookie) {
    
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

        # Remove the Quant Capital cookies (added by some plugin, all __qca)
        set req.http.Cookie = regsuball(req.http.Cookie, "__qc.=[^;]+(; )?", "");

        # Remove the AddThis cookies
        set req.http.Cookie = regsuball(req.http.Cookie, "__atuv.=[^;]+(; )?", "");
    
        # Remove the Hotjar cookies
        set req.http.Cookie = regsuball(req.http.Cookie, "mp_mixpanel__c=[^;]+(; )?", "");

        # Remove the Zopim cookies
        set req.http.Cookie = regsuball(req.http.Cookie, "__zlcmid=[^;]+(; )?", "");

        # Remove a ";" prefix in the cookie if present
        set req.http.Cookie = regsuball(req.http.Cookie, "^;\s*", "");

        # Are there cookies left with only spaces or that are empty?
        if (req.http.cookie ~ "^\s*$") {
            unset req.http.cookie;
        }
    }
    
    # Normalize the Accept-Encoding header
    if (req.http.Accept-Encoding) {
        if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg)$") {
            # No point in compressing these
            unset req.http.Accept-Encoding;
        } elsif (req.http.Accept-Encoding ~ "gzip") {
            set req.http.Accept-Encoding = "gzip";
        } elsif (req.http.Accept-Encoding ~ "deflate" && req.http.user-agent !~ "MSIE") {
            set req.http.Accept-Encoding = "deflate";
        } else {
            # unkown algorithm
            unset req.http.Accept-Encoding;
        }
    }
	
    # Send Surrogate-Capability headers to announce ESI support to backend
    set req.http.Surrogate-Capability = "key=ESI/1.0";
	
    if (req.http.Authorization) {
        # Not cacheable by default
        return (pass);
    }

    return (hash);
}

sub vcl_pipe {
    # Called upon entering pipe mode.
    # In this mode, the request is passed on to the backend, and any further data from both the client
    # and backend is passed on unaltered until either end closes the connection. Basically, Varnish will
    # degrade into a simple TCP proxy, shuffling bytes back and forth. For a connection in pipe mode,
    # no other VCL subroutine will ever get called after vcl_pipe.

    # Note that only the first request to the backend will have
    # X-Forwarded-For set.  If you use X-Forwarded-For and want to
    # have it set for all requests, make sure to have:
    # set bereq.http.connection = "close";
    # here. It is not set by default as it might break some broken web
    # applications, like IIS with NTLM authentication.

    # set bereq.http.Connection = "Close";

    # Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
    if (req.http.upgrade) {
        set bereq.http.upgrade = req.http.upgrade;
    }

    return (pipe);
}

sub vcl_pass {
    # Called upon entering pass mode. In this mode, the request is passed on to the backend, and the
    # backend's response is passed on to the client, but is not entered into the cache. Subsequent
    # requests submitted over the same client connection are handled normally.

    if (req.method == "PURGE") {
        return (synth(502, "PURGE on a passed object"));
    }
	
    #return (pass);
}

# The data on which the hashing will take place
sub vcl_hash {
    # Called after vcl_recv to create a hash value for the request. This is used as a key
    # to look up the object in Varnish.

    hash_data(req.url);

    if (req.http.host) {
        hash_data(req.http.host);
    } else {
        hash_data(server.ip);
    }

    # hash cookies for requests that have them
    if (req.http.Cookie) {
        hash_data(req.http.Cookie);
    }
}

sub vcl_hit {
    # Called when a cache lookup is successful.
	
    if (req.method == "PURGE") {
        return (synth(200, "Purged"));
    }

    if (obj.ttl >= 0s) {
        # A pure unadultered hit, deliver it
        return (deliver);
    }

    # https://www.varnish-cache.org/docs/trunk/users-guide/vcl-grace.html
    # When several clients are requesting the same page Varnish will send one request to the backend and place the others on hold while fetching one copy from the backend. In some products this is called request coalescing and Varnish does this automatically.
    # If you are serving thousands of hits per second the queue of waiting requests can get huge. There are two potential problems - one is a thundering herd problem - suddenly releasing a thousand threads to serve content might send the load sky high. Secondly - nobody likes to wait. To deal with this we can instruct Varnish to keep the objects in cache beyond their TTL and to serve the waiting requests somewhat stale content.

    # We have no fresh fish. Lets look at the stale ones.
    if (std.healthy(req.backend_hint)) {
        # Backend is healthy. Limit age to 10s.
        if (obj.ttl + 10s > 0s) {
            #set req.http.grace = "normal(limited)";
            return (deliver);
        } else {
            # No candidate for grace. Fetch a fresh object.
            return(fetch);
        }
    } else {
        # backend is sick - use full grace
        if (obj.ttl + obj.grace > 0s) {
            #set req.http.grace = "full";
            return (deliver);
        } else {
            # no graced object.
            return (fetch);
        }
    }

    # fetch & deliver once we get the result
    return (fetch); # Dead code, keep as a safeguard
}

sub vcl_miss {
    # Called after a cache lookup if the requested document was not found in the cache. Its purpose
    # is to decide whether or not to attempt to retrieve the document from the backend, and which
    # backend to use.

    if (req.method == "PURGE") {
        return (synth(404, "Not in cache"));
    }
	
    return (fetch);
}

# Handle the HTTP request coming from our backend
sub vcl_backend_response {
    # Happens after we have read the response headers from the backend.
    #
    # Here you clean the response headers, removing silly Set-Cookie headers
    # and other mistakes your backend does.
	
    # Pause ESI request and remove Surrogate-Control header
    if (beresp.http.Surrogate-Control ~ "ESI/1.0") {
        unset beresp.http.Surrogate-Control;
        set beresp.do_esi = true;
    }
    
    # Don't cache requests with "Set-Cookie" headers
    if (beresp.http.Set-Cookie) {
        set beresp.uncacheable = true;
        return (deliver);
    }

    # Don't cache requests with cache-control header that explicitly states that we should not cache.
    if (beresp.http.Cache-Control ~ "(private|no-cache|no-store)") {
        set beresp.uncacheable = true;
        return (deliver);
    }

    # Allow stale content, in case the backend goes down.
    # make Varnish keep all objects for 6 hours beyond their TTL
    set beresp.grace = 6h;

    return (deliver);
}

# The routine when we deliver the HTTP request to the user
# Last chance to modify headers that are sent to the client
sub vcl_deliver {
    # Happens when we have all the pieces we need, and are about to send the
    # response to the client.
    #
    # You can do accounting or modifying the final object here.
	
    # Called before a cached object is delivered to the client.

    # Add debug header to see if it's a HIT/MISS and the number of hits
    if (obj.hits > 0) { 
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
    
    # Add debug header to see the remaining cookies after filtering.
    set resp.http.X-Cookie-Debug = req.http.Cookie;

    # Please note that obj.hits behaviour changed in 4.0, now it counts per objecthead, not per object
    # and obj.hits may not be reset in some cases where bans are in use. See bug 1492 for details.
    # So take hits with a grain of salt
    set resp.http.X-Cache-Hits = obj.hits;

    # Remove some headers: PHP version
    #unset resp.http.X-Powered-By;

    # Remove some headers: Apache version & OS
    unset resp.http.Server;
    unset resp.http.X-Varnish;
    unset resp.http.Via;
    unset resp.http.Link;

    return (deliver);
}

sub vcl_purge {
    # Only handle actual PURGE HTTP methods, everything else is discarded
    if (req.method != "PURGE") {
        # restart request
        set req.http.X-Purge = "Yes";
        return(restart);
    }
}
