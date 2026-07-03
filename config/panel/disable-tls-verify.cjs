const tls = require('tls');
const _connect = tls.connect;
tls.connect = function (options) {
    if (options && typeof options === 'object' && options.ca) {
        const systemCAs = tls.rootCertificates || [];
        options.ca = Array.isArray(options.ca)
            ? [...options.ca, ...systemCAs]
            : [options.ca, ...systemCAs];
    }
    return _connect.apply(this, arguments);
};
