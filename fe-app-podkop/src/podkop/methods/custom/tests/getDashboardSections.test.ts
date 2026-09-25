import { beforeEach, describe, expect, it, vi } from 'vitest';
import { getDashboardSections } from '../getDashboardSections';
import { getConfigSections } from '../getConfigSections';
import { PodkopShellMethods } from '../../shell';

vi.mock('../getConfigSections', () => ({ getConfigSections: vi.fn() }));
vi.mock('../../shell', () => ({
  PodkopShellMethods: {
    getClashApiProxies: vi.fn(),
    getOutboundNames: vi.fn(),
  },
}));

function proxy(name: string, patch: Record<string, unknown> = {}) {
  return {
    type: 'VLESS',
    name,
    udp: true,
    history: [{ time: '', delay: 100 }],
    ...patch,
  };
}

const proxies = {
  'main-out': proxy('main-out'),
  'plain-out': proxy('plain-out'),
  'sel-1-out': proxy('sel-1-out'),
  'sel-2-out': proxy('sel-2-out'),
  'sel-3-out': proxy('sel-3-out'),
  'sel-out': proxy('sel-out', {
    type: 'Selector',
    now: 'sel-2-out',
    all: ['sel-1-out', 'sel-2-out', 'sel-3-out'],
  }),
  'ut-1-out': proxy('ut-1-out'),
  'ut-2-out': proxy('ut-2-out'),
  'ut-urltest-out': proxy('ut-urltest-out', {
    type: 'URLTest',
    now: 'ut-1-out',
    all: ['ut-1-out', 'ut-2-out'],
  }),
  'ut-out': proxy('ut-out', {
    type: 'Selector',
    now: 'ut-urltest-out',
    all: ['ut-1-out', 'ut-2-out', 'ut-urltest-out'],
  }),
};

const outboundNames = {
  'main-out': 'NL%201',
  'plain-out': 'NL%201',
  'sel-1-out': 'Manual',
  'sel-2-out': 'NL%201',
  'ut-1-out': 'NL%201',
  'ut-2-out': '🇩🇪 DE',
};

const configSections = [
  {
    '.name': 'main',
    '.type': 'section',
    connection_type: 'proxy',
    proxy_config_type: 'url',
    proxy_string: 'https://sub.example.com/sub/TOKEN#PaperVPN',
  },
  {
    '.name': 'plain',
    '.type': 'section',
    connection_type: 'proxy',
    proxy_config_type: 'url',
    proxy_string: 'https://sub.example.com/sub/TOKEN',
  },
  {
    '.name': 'sel',
    '.type': 'section',
    connection_type: 'proxy',
    proxy_config_type: 'selector',
    selector_proxy_links: [
      'vless://uuid@1.1.1.1:443?type=tcp&security=tls#Manual',
      'https://sub.example.com/sub/TOKEN',
    ],
  },
  {
    '.name': 'ut',
    '.type': 'section',
    connection_type: 'proxy',
    proxy_config_type: 'urltest',
    urltest_proxy_links: ['https://sub.example.com/sub/TOKEN'],
  },
];

function displayNames(
  sections: Awaited<ReturnType<typeof getDashboardSections>>['data'],
  code: string,
) {
  return sections
    .find((section) => section.displayName === code)
    ?.outbounds.map((outbound) => outbound.displayName);
}

describe('getDashboardSections', () => {
  beforeEach(() => {
    vi.mocked(getConfigSections).mockResolvedValue(configSections as never);
    vi.mocked(PodkopShellMethods.getClashApiProxies).mockResolvedValue({
      success: true,
      data: { proxies },
    });
    vi.mocked(PodkopShellMethods.getOutboundNames).mockResolvedValue({
      success: true,
      data: outboundNames,
    });
  });

  it('keeps the name of the configured link in url mode', async () => {
    const { data } = await getDashboardSections();

    expect(displayNames(data, 'main')).toEqual(['PaperVPN']);
  });

  it('uses the outbound name when the configured link has no name', async () => {
    const { data } = await getDashboardSections();

    expect(displayNames(data, 'plain')).toEqual(['NL 1']);
  });

  it('lists every selector outbound, including subscription links', async () => {
    const { data } = await getDashboardSections();
    const selector = data.find((section) => section.displayName === 'sel');

    expect(selector?.outbounds.map((outbound) => outbound.code)).toEqual([
      'sel-1-out',
      'sel-2-out',
      'sel-3-out',
    ]);
    expect(displayNames(data, 'sel')).toEqual(['Manual', 'NL 1', 'sel-3-out']);
    expect(selector?.outbounds.map((outbound) => outbound.selected)).toEqual([
      false,
      true,
      false,
    ]);
  });

  it('names urltest outbounds by tag', async () => {
    const { data } = await getDashboardSections();

    expect(displayNames(data, 'ut')).toEqual(['Fastest', 'NL 1', '🇩🇪 DE']);
  });

  it('shows the whole outbound name when it contains #', async () => {
    vi.mocked(PodkopShellMethods.getOutboundNames).mockResolvedValue({
      success: true,
      data: { ...outboundNames, 'ut-2-out': 'id%40example.com#Provider_EE' },
    });

    const { data } = await getDashboardSections();

    expect(displayNames(data, 'ut')).toEqual([
      'Fastest',
      'NL 1',
      'id@example.com#Provider_EE',
    ]);
  });

  it('falls back to proxy names when getting outbound names throws', async () => {
    vi.mocked(PodkopShellMethods.getOutboundNames).mockRejectedValue(
      new Error('Operation timed out'),
    );

    const { success, data } = await getDashboardSections();

    expect(success).toBe(true);
    expect(displayNames(data, 'ut')).toEqual([
      'Fastest',
      'ut-1-out',
      'ut-2-out',
    ]);
  });

  it('falls back to proxy names when outbound names are unavailable', async () => {
    vi.mocked(PodkopShellMethods.getOutboundNames).mockResolvedValue({
      success: false,
      error: '',
    });

    const { success, data } = await getDashboardSections();

    expect(success).toBe(true);
    expect(displayNames(data, 'sel')).toEqual([
      'sel-1-out',
      'sel-2-out',
      'sel-3-out',
    ]);
  });
});
