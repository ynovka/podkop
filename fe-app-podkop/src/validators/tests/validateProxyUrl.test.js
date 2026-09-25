import { describe, it, expect } from 'vitest';
import { validateProxyUrl } from '../validateProxyUrl';

const validUrls = [
  ['HTTPS subscription', 'https://example.azure-api.net/abc123/TOKEN#PaperVPN'],
  ['HTTPS subscription with port', 'https://sub.example.com:8443/sub/TOKEN'],
  ['HTTPS subscription with query', 'https://sub.example.com/sub?token=abc'],
  [
    'HTTPS subscription with whitespace',
    '  https://sub.example.com/sub/TOKEN\n',
  ],
  [
    'VLESS',
    'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@127.0.0.1:34520?type=tcp&encryption=none&security=none#vless-tcp-none',
  ],
  [
    'Shadowsocks',
    'ss://2022-blake3-aes-256-gcm:dmCly/Zh15Ww9+s+GFXiFTIkpw7c/qCISaBrai7WhhY=@127.0.0.1:27214?type=tcp#shadowsocks-plain-user',
  ],
  ['Socks5', 'socks5://127.0.0.1:1080'],
];

const invalidUrls = [
  ['HTTP subscription', 'http://sub.example.com/sub/TOKEN'],
  ['HTTPS without host', 'https://'],
  ['HTTPS with spaces', 'https://sub.example.com/sub TOKEN'],
  ['Unsupported scheme', 'vmess://eyJhZGQiOiIxLjIuMy40In0='],
  ['Plain text', 'not a url'],
];

describe('validateProxyUrl', () => {
  describe.each(validUrls)('Valid URL: %s', (_desc, url) => {
    it(`returns valid=true for "${url}"`, () => {
      const res = validateProxyUrl(url);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidUrls)('Invalid URL: %s', (_desc, url) => {
    it(`returns valid=false for "${url}"`, () => {
      const res = validateProxyUrl(url);
      expect(res.valid).toBe(false);
    });
  });
});
