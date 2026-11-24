// ==UserScript==
// @name         ChatGPT Payload Inspector
// @namespace    local.chatgpt.payloadinspector
// @version      1.0.0
// @description  Inspect complete ChatGPT conversation request and response payloads
// @match        https://chatgpt.com/*
// @run-at       document-start
// @sandbox      raw
// @grant        none
// ==/UserScript==

(() => {
    "use strict";

    // Inspect conversation-related backend requests, including init and prepare.
    // This script is read-only: it never changes request or response data.
    const TARGET_URL_PATTERN =
        /\/backend-api\/(?:f\/)?conversation(?:[/?#]|$)/;

    const KEY = "__CHATGPT_PAYLOAD_INSPECTOR__";

    window[KEY]?.stop?.();

    let enabled = true;
    let sequence = 0;

    const nativeFetch = window.fetch;
    const xhrOpen = XMLHttpRequest.prototype.open;
    const xhrSend = XMLHttpRequest.prototype.send;
    const xhrInfo = new WeakMap();

    function nextId() {
        sequence += 1;
        return sequence;
    }

    function getUrl(input) {
        if (typeof input === "string") return input;
        return input?.url || "";
    }

    function getMethod(input, init) {
        const isRequest =
            typeof Request !== "undefined" && input instanceof Request;

        return String(
            init?.method || (isRequest ? input.method : "GET")
        ).toUpperCase();
    }

    function matches(url) {
        return TARGET_URL_PATTERN.test(String(url || ""));
    }

    function fileInfo(value) {
        return {
            type: value?.constructor?.name || "File",
            name: value?.name,
            size: value?.size,
            mimeType: value?.type,
            lastModified: value?.lastModified
        };
    }

    function formDataObject(formData) {
        const result = {};

        for (const [key, value] of formData.entries()) {
            const item = typeof value === "string" ? value : fileInfo(value);

            if (Object.prototype.hasOwnProperty.call(result, key)) {
                if (!Array.isArray(result[key])) result[key] = [result[key]];
                result[key].push(item);
            } else {
                result[key] = item;
            }
        }

        return result;
    }

    function printGroup(title, metadata, value, label) {
        console.groupCollapsed(title);
        if (metadata) console.info("Request details:", metadata);
        if (label) console.info("Format:", label);
        console.dir(value);
        console.groupEnd();
    }

    function inspectText(text, source, metadata) {
        if (typeof text !== "string") return;

        const trimmed = text.trim();

        if (!trimmed) {
            printGroup(source, metadata, "(empty body)", "empty");
            return;
        }

        try {
            const parsed = JSON.parse(text);
            printGroup(source, metadata, parsed, "JSON");
            return;
        } catch {
            // Try parsing a Server-Sent Events stream below.
        }

        const lines = text.split(/\r?\n/);
        const hasSse = lines.some(line =>
            /^(data|event|id|retry):/.test(line.trim())
        );

        if (hasSse) {
            console.groupCollapsed(source);
            if (metadata) console.info("Request details:", metadata);
            console.info("Format: Server-Sent Events");

            let eventRecord = {};

            function flushRecord() {
                if (!Object.keys(eventRecord).length) return;

                if (Array.isArray(eventRecord.data)) {
                    const dataText = eventRecord.data.join("\n");

                    if (dataText === "[DONE]") {
                        console.info("SSE stream marker:", dataText);
                    } else {
                        try {
                            console.info("SSE data (JSON):", JSON.parse(dataText));
                        } catch {
                            console.info("SSE data (text):", dataText);
                        }
                    }
                }

                if (eventRecord.event || eventRecord.id || eventRecord.retry) {
                    console.info("SSE event metadata:", {
                        event: eventRecord.event,
                        id: eventRecord.id,
                        retry: eventRecord.retry
                    });
                }

                eventRecord = {};
            }

            for (const line of lines) {
                if (!line.trim()) {
                    flushRecord();
                    continue;
                }

                if (line.startsWith(":")) {
                    console.info("SSE comment:", line.slice(1).trim());
                    continue;
                }

                const separator = line.indexOf(":");
                const field = separator < 0 ? line : line.slice(0, separator);
                let value = separator < 0 ? "" : line.slice(separator + 1);
                if (value.startsWith(" ")) value = value.slice(1);

                if (field === "data") {
                    if (!eventRecord.data) eventRecord.data = [];
                    eventRecord.data.push(value);
                } else if (
                    field === "event" ||
                    field === "id" ||
                    field === "retry"
                ) {
                    eventRecord[field] = value;
                } else {
                    console.info("SSE field:", field, value);
                }
            }

            flushRecord();
            console.groupEnd();
            return;
        }

        printGroup(source, metadata, text, "plain text");
    }

    function inspectBody(body, source, metadata) {
        if (body == null) {
            printGroup(source, metadata, "(no request body)", "empty");
            return;
        }

        if (typeof body === "string") {
            inspectText(body, source, metadata);
            return;
        }

        if (typeof FormData !== "undefined" && body instanceof FormData) {
            printGroup(
                source,
                metadata,
                formDataObject(body),
                "FormData (file contents represented by metadata)"
            );
            return;
        }

        if (typeof URLSearchParams !== "undefined" && body instanceof URLSearchParams) {
            printGroup(
                source,
                metadata,
                Array.from(body.entries()),
                "URL-encoded form entries"
            );
            return;
        }

        if (typeof Blob !== "undefined" && body instanceof Blob) {
            body.text().then(text => {
                inspectText(text, source, {
                    ...metadata,
                    blobSize: body.size,
                    blobType: body.type
                });
            }).catch(error => {
                console.warn("[PayloadInspector] Could not read Blob body:", error);
            });
            return;
        }

        if (body instanceof ArrayBuffer) {
            inspectText(
                new TextDecoder().decode(body),
                source,
                { ...metadata, byteLength: body.byteLength }
            );
            return;
        }

        if (ArrayBuffer.isView(body)) {
            inspectText(
                new TextDecoder().decode(body),
                source,
                { ...metadata, byteLength: body.byteLength }
            );
            return;
        }

        printGroup(
            source,
            metadata,
            body,
            "unparsed body object"
        );
    }

    function inspectRequestObject(request, source, metadata) {
        try {
            const clone = request.clone();
            const contentType = clone.headers.get("content-type") || "";

            if (
                contentType.includes("multipart/form-data") ||
                contentType.includes("application/x-www-form-urlencoded")
            ) {
                clone.formData().then(formData => {
                    inspectBody(formData, source, {
                        ...metadata,
                        contentType
                    });
                }).catch(() => {
                    clone.text().then(text => {
                        inspectText(text, source, { ...metadata, contentType });
                    }).catch(error => {
                        console.warn("[PayloadInspector] Could not read request:", error);
                    });
                });
                return;
            }

            clone.text().then(text => {
                inspectText(text, source, { ...metadata, contentType });
            }).catch(error => {
                console.warn("[PayloadInspector] Could not read request:", error);
            });
        } catch (error) {
            console.warn("[PayloadInspector] Could not clone request:", error);
        }
    }

    function inspectFetchResponse(response, id, url, method) {
        const contentType = response.headers.get("content-type") || "";

        console.groupCollapsed(
            "[PayloadInspector #" + id + "] FETCH RESPONSE " +
            response.status + " " + url
        );
        console.info("Method:", method);
        console.info("Status:", response.status, response.statusText);
        console.info("Content-Type:", contentType);
        console.groupEnd();

        try {
            response.clone().text().then(text => {
                inspectText(
                    text,
                    "[PayloadInspector #" + id + "] FETCH RESPONSE BODY",
                    { url, method, status: response.status, contentType }
                );
            }).catch(error => {
                console.warn("[PayloadInspector #" + id + "] Response read failed:", error);
            });
        } catch (error) {
            console.warn("[PayloadInspector #" + id + "] Response clone failed:", error);
        }
    }

    window.fetch = function(input, init) {
        if (!enabled) return nativeFetch.apply(this, arguments);

        const url = getUrl(input);
        const method = getMethod(input, init);

        if (!matches(url)) {
            return nativeFetch.apply(this, arguments);
        }

        const id = nextId();
        const isRequest =
            typeof Request !== "undefined" && input instanceof Request;

        const metadata = {
            id,
            transport: "fetch",
            method,
            url,
            contentType:
                init?.headers?.get?.("content-type") ||
                (isRequest ? input.headers.get("content-type") : null)
        };

        console.groupCollapsed(
            "[PayloadInspector #" + id + "] FETCH REQUEST " + method + " " + url
        );
        console.info("Request details:", metadata);
        console.groupEnd();

        if (Object.prototype.hasOwnProperty.call(init || {}, "body")) {
            inspectBody(
                init.body,
                "[PayloadInspector #" + id + "] FETCH REQUEST BODY",
                metadata
            );
        } else if (isRequest && input.body) {
            inspectRequestObject(
                input,
                "[PayloadInspector #" + id + "] FETCH REQUEST BODY",
                metadata
            );
        } else {
            inspectBody(
                null,
                "[PayloadInspector #" + id + "] FETCH REQUEST BODY",
                metadata
            );
        }

        const requestPromise = nativeFetch.apply(this, arguments);

        return requestPromise.then(response => {
            inspectFetchResponse(response, id, url, method);
            return response;
        }, error => {
            console.error("[PayloadInspector #" + id + "] FETCH FAILED:", error);
            throw error;
        });
    };

    XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        xhrInfo.set(this, {
            method: String(method).toUpperCase(),
            url: String(url)
        });

        return xhrOpen.call(this, method, url, ...rest);
    };

    XMLHttpRequest.prototype.send = function(body) {
        const info = xhrInfo.get(this);

        if (!enabled || !info || !matches(info.url)) {
            return xhrSend.call(this, body);
        }

        const id = nextId();
        const metadata = {
            id,
            transport: "xhr",
            method: info.method,
            url: info.url
        };

        inspectBody(
            body,
            "[PayloadInspector #" + id + "] XHR REQUEST BODY",
            metadata
        );

        this.addEventListener("load", () => {
            const responseMetadata = {
                ...metadata,
                status: this.status,
                statusText: this.statusText,
                responseType: this.responseType
            };

            try {
                if (typeof this.responseText === "string") {
                    inspectText(
                        this.responseText,
                        "[PayloadInspector #" + id + "] XHR RESPONSE BODY",
                        responseMetadata
                    );
                    return;
                }

                if (this.response instanceof Blob) {
                    this.response.text().then(text => {
                        inspectText(
                            text,
                            "[PayloadInspector #" + id + "] XHR RESPONSE BODY",
                            responseMetadata
                        );
                    });
                    return;
                }

                if (this.response instanceof ArrayBuffer) {
                    inspectText(
                        new TextDecoder().decode(this.response),
                        "[PayloadInspector #" + id + "] XHR RESPONSE BODY",
                        responseMetadata
                    );
                    return;
                }

                printGroup(
                    "[PayloadInspector #" + id + "] XHR RESPONSE BODY",
                    responseMetadata,
                    this.response,
                    "XHR response object"
                );
            } catch (error) {
                console.warn("[PayloadInspector #" + id + "] XHR response read failed:", error);
            }
        }, { once: true });

        this.addEventListener("error", () => {
            console.error("[PayloadInspector #" + id + "] XHR FAILED:", metadata);
        }, { once: true });

        return xhrSend.call(this, body);
    };

    const wrappedFetch = window.fetch;
    const wrappedOpen = XMLHttpRequest.prototype.open;
    const wrappedSend = XMLHttpRequest.prototype.send;

    function stop() {
        enabled = false;

        if (window.fetch === wrappedFetch) {
            window.fetch = nativeFetch;
        }

        if (XMLHttpRequest.prototype.open === wrappedOpen) {
            XMLHttpRequest.prototype.open = xhrOpen;
        }

        if (XMLHttpRequest.prototype.send === wrappedSend) {
            XMLHttpRequest.prototype.send = xhrSend;
        }

        console.info("[PayloadInspector] Stopped.");
    }

    window[KEY] = {
        get enabled() {
            return enabled;
        },
        toggle() {
            enabled = !enabled;
            console.info("[PayloadInspector] Enabled:", enabled);
            return enabled;
        },
        stop
    };

    console.info(
        "[PayloadInspector] Installed. Monitoring conversation request/response bodies."
    );
})();
