const tls = require('tls');
const net = require('net');
const _createSecureContext = tls.createSecureContext;
const _connect = tls.connect;
const systemCAs = [...(tls.rootCertificates || [])];

tls.createSecureContext = function (options) {
    if (options && options.ca && systemCAs.length > 0) {
        options = { ...options };
        options.ca = Array.isArray(options.ca)
            ? [...options.ca, ...systemCAs]
            : [options.ca, ...systemCAs];
    }
    return _createSecureContext.call(this, options);
};

// Remnawave Panel 3.x AxiosService 会对所有节点连接发送派生 SNI
// （deriveSni(caCert, jwtPublicKey)，形如 763283...361f6f05da.io）。
// PaaS 平台边缘（onrender/koyeb 等）只认可自身域名的 SNI，收到派生
// SNI 会回 TLS alert 40。对公网域名:443 且 servername 为派生 SNI 的
// 握手，改用实际 host 作为 SNI；直连节点（非 443 公网域名）不受影响。
const DERIVED_SNI = /^[0-9a-f]{32}\.[0-9a-f]{10}\.(?:com|net|org|io|dev|app)$/;

tls.connect = function (...args) {
    const options = args[0];
    if (
        options &&
        typeof options === 'object' &&
        DERIVED_SNI.test(options.servername || '') &&
        options.port === 443 &&
        options.host &&
        !net.isIP(options.host)
    ) {
        args[0] = { ...options, servername: options.host };
    }
    return _connect.apply(this, args);
};
