# PaaS HTTPS Root CA 参考

`free-provider-root-ca-bundle.pem` 是给 PaaS HTTPS 直连方案准备的公共 Root CA 参考包，可用于追加到 Remnawave Panel 数据库 `keygen.ca_cert` 字段。

使用时建议先确认 PaaS 分配域名的实际证书链，再按需复制本目录中的 PEM 内容。这个 bundle 适合作为常见免费/托管平台 HTTPS 证书链的起点，但不保证覆盖所有 PaaS、所有区域或所有自定义域名证书。

## 包含的 Root CA

| # | Root CA | 机构 | 常见用途 | 有效期至 | SHA256 指纹 |
|---|---------|------|----------|----------|-------------|
| 1 | ISRG Root X1 | Internet Security Research Group | Let's Encrypt RSA 证书链 | 2035-06-04 | `96BCEC06264976F37460779ACF28C5A7CFE8A3C0AAE11A8FFCEE05C0BDDF08C6` |
| 2 | ISRG Root X2 | Internet Security Research Group | Let's Encrypt ECDSA 证书链 | 2040-09-18 | `69729B8E15A86EFC177A57AFB7171DFC64ADD28C2FCA8CF1507E34453CCB1470` |
| 3 | GTS Root R1 | Google Trust Services LLC | Google Trust Services RSA 证书链 | 2036-06-22 | `D947432ABDE7B7FA90FC2E6B59101B1280E0E1C7E4E40FA3C6887FFF57A7F4CF` |
| 4 | GTS Root R2 | Google Trust Services LLC | Google Trust Services RSA 证书链 | 2036-06-22 | `8D25CD97229DBF70356BDA4EB3CC734031E24CF00FAFCFD32DC76EB5841C7EA8` |
| 5 | GTS Root R3 | Google Trust Services LLC | Google Trust Services ECC 证书链 | 2036-06-22 | `34D8A73EE208D9BCDB0D956520934B4E40E69482596E8B6F73C8426B010A6F48` |
| 6 | GTS Root R4 | Google Trust Services LLC | Google Trust Services ECC 证书链 | 2036-06-22 | `349DFA4058C5E263123B398AE795573C4E1313C83FE68F93556CD5E8031B3C7D` |
| 7 | USERTrust RSA Certification Authority | The USERTRUST Network / Sectigo | Sectigo / ZeroSSL 等 RSA 证书链 | 2038-01-19 | `E793C9B02FD8AA13E21C31228ACCB08119643B749C898964B1746D46C3D4CBD2` |
| 8 | USERTrust ECC Certification Authority | The USERTRUST Network / Sectigo | Sectigo / ZeroSSL 等 ECC 证书链 | 2038-01-19 | `4FF460D54B9C86DABFBCFC5712E0400D2BED3FBC4D4FBDAA86E06ADCD2A9AD7A` |

## 使用建议

- 如果 PaaS 使用系统可信公共证书，优先把实际链路根证书加入 `keygen.ca_cert`；不确定时可先使用整个 `free-provider-root-ca-bundle.pem` 作为参考包。
- 如果 PaaS 使用自定义域名证书、私有 CA、企业代理证书或区域化证书链，需要额外追加对应 Root CA。
- 不要把节点自签证书当作 PaaS HTTPS 域名的 Root CA 使用；PaaS 直连校验的是 Panel 到 PaaS HTTPS 域名这一段的公共证书链。
