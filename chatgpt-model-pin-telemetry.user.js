// ==UserScript==
// @name         ChatGPT Model Pin + Reasoning + Model Slug Monitor
// @namespace    local.chatgpt.modelpin
// @version      3.2.0
// @description  Pin ChatGPT Web model, model slug, and reasoning effort; monitor model metadata
// @match        https://chatgpt.com/*
// @run-at       document-start
// @sandbox      raw
// @grant        none
// ==/UserScript==

(() => {
    "use strict";

    // Choose the requested model and reasoning effort.
    // Examples:
    //   gpt-5.6-terra-wm
    //   gpt-5.6-luna-wm
    //   gpt-6-sol
    //   gpt-6-astra
    //   auto
    const TARGET_MODEL = "auto";
    const TARGET_MODEL_SLUG = "gpt-6-sol";
    const TARGET_THINKING_EFFORT = "extended";

    // TARGET_MODEL is written to payload.model.
    // TARGET_MODEL_SLUG is additionally written to payload.model_slug.
    // The server may ignore unrecognized fields; this is an explicit test.
    const PATCH_PATTERN =
        /\/backend-api\/(?:f\/)?conversation(?:\/prepare)?(?:[?#]|$)/;

    // Observe init metadata too, but do not try to patch its request body.
    const OBSERVE_CONVERSATION_PATTERN =
        /\/backend-api\/(?:f\/)?conversation(?:\/(?:prepare|init))?(?:[/?#]|$)/;

    const TELEMETRY_PATTERN =
        /\/ces\/v1\/telemetry\/intake(?:[/?#]|$)/;

    const KEY = "__CHATGPT_MODEL_PIN__";
    const MODEL_FIELDS = new Set([
        "model_slug",
        "default_model_slug",
        "resolved_model_slug",
        "last_message_model_slug",
        "intended_default_model_slug"
    ]);

    // Remove previous instance.
    window[KEY]?.stop?.();

    let enabled = true;

    const nativeFetch = window.fetch;
    const xhrOpen = XMLHttpRequest.prototype.open;
    const xhrSend = XMLHttpRequest.prototype.send;
    const xhrInfo = new WeakMap();

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

    function isConversationPatch(url, method) {
        return method === "POST" && PATCH_PATTERN.test(url);
    }

    function shouldObserve(url) {
        return OBSERVE_CONVERSATION_PATTERN.test(url) ||
               TELEMETRY_PATTERN.test(url);
    }

    function collectPayloadFields(value) {
        const fields = new Set([
            "model",
            "model_slug",
            "default_model_slug",
            "intended_default_model_slug",
            "resolved_model_slug",
            "thinking_effort",
            "plan_type"
        ]);

        const found = {};

        function walk(node, path = "", depth = 0) {
            if (!node || typeof node !== "object" || depth > 8) return;

            for (const [key, child] of Object.entries(node)) {
                const current = path ? `${path}.${key}` : key;

                if (fields.has(key)) found[current] = child;

                if (child && typeof child === "object") {
                    walk(child, current, depth + 1);
                }
            }
        }

        walk(value);
        return found;
    }

    function patchBody(body, transport) {
        if (typeof body !== "string") {
            console.warn(
                "[ModelPin] Unsupported request body; not modified:",
                transport
            );
            return body;
        }

        let payload;

        try {
            payload = JSON.parse(body);
        } catch {
            console.warn(
                "[ModelPin] Request body isn't JSON; not modified:",
                transport
            );
            return body;
        }

        if (
            !payload ||
            typeof payload !== "object" ||
            !Object.prototype.hasOwnProperty.call(payload, "model")
        ) {
            // Some observed endpoints, such as /conversation/init, do not
            // use the conversation-generation request schema.
            return body;
        }

        const previousModel = payload.model;
        const previousModelSlug = payload.model_slug;
        const previousEffort = payload.thinking_effort;
        const payloadBefore = collectPayloadFields(payload);

        payload.model = TARGET_MODEL;
        payload.model_slug = TARGET_MODEL_SLUG;
        payload.thinking_effort = TARGET_THINKING_EFFORT;

        console.groupCollapsed(`[ModelPin] Outgoing payload (${transport})`);
        console.info("Before:", payloadBefore);
        console.info("After:", collectPayloadFields(payload));
        console.info("Top-level keys:", Object.keys(payload));
        console.groupEnd();

        if (
            previousModel === TARGET_MODEL &&
            previousModelSlug === TARGET_MODEL_SLUG &&
            previousEffort === TARGET_THINKING_EFFORT
        ) {
            return body;
        }

        console.info(
            `[ModelPin] Model: ${previousModel} -> ${TARGET_MODEL}`,
            transport
        );

        console.info(
            `[ModelPin] Model slug: ${previousModelSlug ?? "unset"} -> ${TARGET_MODEL_SLUG}`,
            transport
        );

        console.info(
            `[ModelPin] Thinking effort: ${previousEffort ?? "default"} -> ${TARGET_THINKING_EFFORT}`,
            transport
        );

        return JSON.stringify(payload);
    }

    function reportModelFields(value, source) {
        const found = [];

        function walk(node, path, depth) {
            if (depth > 12 || node === null || typeof node !== "object") {
                return;
            }

            if (Array.isArray(node)) {
                node.forEach((item, index) =>
                    walk(item, `${path}[${index}]`, depth + 1)
                );
                return;
            }

            for (const [key, child] of Object.entries(node)) {
                const childPath = path ? `${path}.${key}` : key;

                if (MODEL_FIELDS.has(key)) {
                    found.push({
                        path: childPath,
                        value: child
                    });
                }

                walk(child, childPath, depth + 1);
            }
        }

        walk(value, "", 0);

        if (found.length) {
            console.groupCollapsed(
                `[ModelPin] Model metadata (${source})`
            );

            for (const item of found) {
                console.info(item.path, item.value);
            }

            console.groupEnd();
        }
    }

    function inspectText(text, source) {
        if (typeof text !== "string" || !text.trim()) return;

        // Normal JSON response or telemetry request.
        try {
            reportModelFields(JSON.parse(text), source);
            return;
        } catch {
            // Conversation responses may be streamed as SSE.
        }

        // Inspect JSON objects carried in SSE "data:" lines.
        for (const line of text.split(/\r?\n/)) {
            const trimmed = line.trim();
            if (!trimmed.startsWith("data:")) continue;

            const data = trimmed.slice(5).trim();
            if (!data || data === "[DONE]") continue;

            try {
                reportModelFields(JSON.parse(data), `${source} (SSE)`);
            } catch {
                // Ignore non-JSON SSE lines.
            }
        }
    }

    function inspectRequestBody(body, source) {
        if (typeof body === "string") {
            inspectText(body, source);
        }
    }

    function inspectResponse(response, source) {
        try {
            response.clone().text().then(text => {
                inspectText(text, source);
            }).catch(() => {
                // Do not interfere with the original response.
            });
        } catch {
            // Response inspection is best-effort only.
        }
    }

    function sendFetch(input, init, url, observe) {
        const request = nativeFetch.call(this, input, init);

        if (!observe) return request;

        return request.then(response => {
            inspectResponse(response, url);
            return response;
        });
    }

    // FETCH interception.
    window.fetch = function(input, init) {
        if (!enabled) {
            return nativeFetch.apply(this, arguments);
        }

        const isRequest =
            typeof Request !== "undefined" && input instanceof Request;

        const url = getUrl(input);
        const method = getMethod(input, init);
        const patch = isConversationPatch(url, method);
        const observe = shouldObserve(url);

        if (!patch && !observe) {
            return nativeFetch.apply(this, arguments);
        }

        // A string body supplied through fetch init.
        if (typeof init?.body === "string") {
            if (observe) {
                inspectRequestBody(init.body, `${url} request`);
            }

            const modified = patch
                ? patchBody(init.body, "fetch")
                : init.body;

            const nextInit = modified === init.body
                ? init
                : { ...init, body: modified };

            return sendFetch.call(this, input, nextInit, url, observe);
        }

        // A Request object may carry the body when init.body is absent.
        if (
            isRequest &&
            (!init ||
             !Object.prototype.hasOwnProperty.call(init, "body"))
        ) {
            return input.clone().text().then(body => {
                if (observe) {
                    inspectRequestBody(body, `${url} request`);
                }

                const modified = patch
                    ? patchBody(body, "fetch Request")
                    : body;

                if (modified === body) {
                    return sendFetch.call(this, input, init, url, observe);
                }

                const replacement = new Request(input, {
                    ...(init || {}),
                    body: modified
                });

                return sendFetch.call(this, replacement, undefined, url, observe);
            });
        }

        if (patch) {
            console.warn(
                "[ModelPin] Matched conversation request, but couldn't " +
                "access its JSON body. Request left unchanged."
            );
        }

        return sendFetch.call(this, input, init, url, observe);
    };

    // XMLHttpRequest interception.
    XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        xhrInfo.set(this, {
            method: String(method),
            url: String(url)
        });

        return xhrOpen.call(this, method, url, ...rest);
    };

    XMLHttpRequest.prototype.send = function(body) {
        const info = xhrInfo.get(this);

        if (!enabled || !info) {
            return xhrSend.call(this, body);
        }

        const patch = isConversationPatch(
            info.url,
            info.method.toUpperCase()
        );
        const observe = shouldObserve(info.url);

        if (observe) {
            inspectRequestBody(body, `${info.url} XHR request`);

            this.addEventListener("load", () => {
                try {
                    const responseText =
                        typeof this.responseText === "string"
                            ? this.responseText
                            : (
                                this.response &&
                                typeof this.response === "object"
                                    ? JSON.stringify(this.response)
                                    : ""
                            );

                    inspectText(responseText, `${info.url} XHR response`);
                } catch {
                    // responseText may be unavailable for some responseTypes.
                }
            }, { once: true });
        }

        if (patch) {
            body = patchBody(body, "XHR");
        }

        return xhrSend.call(this, body);
    };

    const wrappedFetch = window.fetch;

    function stop() {
        enabled = false;

        if (window.fetch === wrappedFetch) {
            window.fetch = nativeFetch;
        }

        XMLHttpRequest.prototype.open = xhrOpen;
        XMLHttpRequest.prototype.send = xhrSend;

        console.info("[ModelPin] Stopped.");
    }

    window[KEY] = {
        target: TARGET_MODEL,
        modelSlug: TARGET_MODEL_SLUG,
        reasoning: TARGET_THINKING_EFFORT,

        get enabled() {
            return enabled;
        },

        toggle() {
            enabled = !enabled;

            console.info("[ModelPin] Enabled:", enabled);
            return enabled;
        },

        stop
    };

    console.info(
        `[ModelPin] Installed. Model: ${TARGET_MODEL}; ` +
        `Model slug: ${TARGET_MODEL_SLUG}; ` +
        `Thinking effort: ${TARGET_THINKING_EFFORT}`
    );
})();