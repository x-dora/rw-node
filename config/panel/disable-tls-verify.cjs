const tls = require('tls');
const _createSecureContext = tls.createSecureContext;
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
