start_haproxy_front() {
    local config_path="${HAPROXY_CONF_DIR}/haproxy.cfg"
    local log_prefix="${HAPROXY_LOG_PREFIX:-[PaaS FRP]}"

    if ! is_port "${HTTP_FRONT_PORT}"; then
        echo "${log_prefix} ERROR: HTTP_FRONT_PORT must be a valid TCP port"
        exit 1
    fi

    if [[ "${HTTP_FRONT_PORT}" == "${NODE_PORT}" ]]; then
        echo "${log_prefix} ERROR: HTTP_FRONT_PORT must differ from NODE_PORT"
        exit 1
    fi

    if ! is_port "${XHTTP_UPSTREAM_PORT}"; then
        echo "${log_prefix} ERROR: XHTTP_UPSTREAM_PORT must be a valid TCP port"
        exit 1
    fi

    if ! is_port "${WS_UPSTREAM_PORT}"; then
        echo "${log_prefix} ERROR: WS_UPSTREAM_PORT must be a valid TCP port"
        exit 1
    fi

    if [[ ! -x "${HAPROXY_BIN}" ]]; then
        echo "${log_prefix} ERROR: haproxy binary not found"
        exit 1
    fi

    mkdir -p "${HAPROXY_CONF_DIR}"

    cat > "${config_path}" << EOF
global
    maxconn 1024
    nbthread 1
    log stdout format raw local0 warning

defaults
    mode http
    log global
    option dontlognull
    timeout connect 5s
    timeout client 1h
    timeout server 1h
    timeout tunnel 1h

frontend http_front
    bind *:${HTTP_FRONT_PORT}
    acl is_health path -i /health
    acl is_xh path_beg -i /xh-
    acl is_ws path_beg -i /ws-
    acl is_node_api path_beg -i /node/
    acl is_vision_api path_beg -i /vision/

    http-request return status 200 content-type text/plain string "ok\n" if is_health
    http-request return status 404 if !is_health !is_xh !is_ws !is_node_api !is_vision_api
    use_backend xhttp_backend if is_xh
    use_backend ws_backend if is_ws
    use_backend node_api_backend if is_node_api
    use_backend node_api_backend if is_vision_api

backend xhttp_backend
    option http-no-delay
    server xhttp 127.0.0.1:${XHTTP_UPSTREAM_PORT}

backend ws_backend
    option http-server-close
    timeout tunnel 1h
    server ws 127.0.0.1:${WS_UPSTREAM_PORT}

backend node_api_backend
    option http-server-close
    server node_api 127.0.0.1:${NODE_PORT} ssl verify none
EOF

    "${HAPROXY_BIN}" -c -f "${config_path}"

    echo "${log_prefix} Starting HAProxy HTTP front on port ${HTTP_FRONT_PORT}"
    "${HAPROXY_BIN}" -W -db -f "${config_path}" &
    haproxy_pid=$!

    if ! wait_for_port "${HTTP_FRONT_PORT}" "${haproxy_pid}"; then
        echo "${log_prefix} ERROR: HAProxy did not accept TCP connections on 127.0.0.1:${HTTP_FRONT_PORT}"
        terminate
        exit 1
    fi
}
