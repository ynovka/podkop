import { getConfigSections } from './getConfigSections';
import { Podkop } from '../../types';
import { getProxyUrlName } from '../../../helpers/getProxyUrlName';
import { splitProxyString } from '../../../helpers/splitProxyString';
import { PodkopShellMethods } from '../shell';

interface IGetDashboardSectionsResponse {
  success: boolean;
  data: Podkop.OutboundGroup[];
}

export async function getDashboardSections(): Promise<IGetDashboardSectionsResponse> {
  const configSections = await getConfigSections();
  const [clashProxies, outboundNamesResponse] = await Promise.all([
    PodkopShellMethods.getClashApiProxies(),
    // Names are optional: the dashboard falls back to proxy names without them
    PodkopShellMethods.getOutboundNames().catch(() => ({
      success: false as const,
      error: '',
    })),
  ]);

  if (!clashProxies.success) {
    return {
      success: false,
      data: [],
    };
  }

  const proxies = Object.entries(clashProxies.data.proxies).map(
    ([key, value]) => ({
      code: key,
      value,
    }),
  );

  // Outbound names are URL fragments of the links the backend created the outbounds from.
  // Links from subscriptions are not in the config, so the names can't be taken from the section.
  const outboundNames = outboundNamesResponse.success
    ? outboundNamesResponse.data
    : {};
  // The whole fragment is the name: it may contain '#' itself
  const getOutboundName = (code: string) => {
    const name = outboundNames[code];

    if (!name) {
      return '';
    }

    try {
      return decodeURIComponent(name);
    } catch {
      return name;
    }
  };

  const data = configSections
    .filter(
      (section) =>
        section.connection_type !== 'block' &&
        section.connection_type !== 'exclusion' &&
        section['.type'] !== 'settings',
    )
    .map((section) => {
      if (section.connection_type === 'proxy') {
        if (section.proxy_config_type === 'url') {
          const outbound = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );

          const activeConfigs = splitProxyString(section.proxy_string);

          const proxyDisplayName =
            getProxyUrlName(activeConfigs?.[0]) ||
            getOutboundName(`${section['.name']}-out`) ||
            outbound?.value?.name ||
            '';

          return {
            withTagSelect: false,
            code: outbound?.code || section['.name'],
            displayName: section['.name'],
            outbounds: [
              {
                code: outbound?.code || section['.name'],
                displayName: proxyDisplayName,
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
              },
            ],
          };
        }

        if (section.proxy_config_type === 'outbound') {
          const outbound = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );

          const parsedOutbound = JSON.parse(section.outbound_json);
          const parsedTag = parsedOutbound?.tag
            ? decodeURIComponent(parsedOutbound?.tag)
            : undefined;
          const proxyDisplayName = parsedTag || outbound?.value?.name || '';

          return {
            withTagSelect: false,
            code: outbound?.code || section['.name'],
            displayName: section['.name'],
            outbounds: [
              {
                code: outbound?.code || section['.name'],
                displayName: proxyDisplayName,
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
              },
            ],
          };
        }

        if (section.proxy_config_type === 'selector') {
          const selector = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );

          const outbounds = (selector?.value?.all ?? [])
            .map((code) => proxies.find((item) => item.code === code))
            .map((item) => ({
              code: item?.code || '',
              displayName:
                getOutboundName(item?.code || '') || item?.value?.name || '',
              latency: item?.value?.history?.[0]?.delay || 0,
              type: item?.value?.type || '',
              selected: selector?.value?.now === item?.code,
            }));

          return {
            withTagSelect: true,
            code: selector?.code || section['.name'],
            displayName: section['.name'],
            outbounds,
          };
        }

        if (section.proxy_config_type === 'urltest') {
          const selector = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );
          const outbound = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-urltest-out`,
          );

          const outbounds = (outbound?.value?.all ?? [])
            .map((code) => proxies.find((item) => item.code === code))
            .map((item) => ({
              code: item?.code || '',
              displayName:
                getOutboundName(item?.code || '') || item?.value?.name || '',
              latency: item?.value?.history?.[0]?.delay || 0,
              type: item?.value?.type || '',
              selected: selector?.value?.now === item?.code,
            }));

          return {
            withTagSelect: true,
            code: selector?.code || section['.name'],
            displayName: section['.name'],
            outbounds: [
              {
                code: outbound?.code || '',
                displayName: _('Fastest'),
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: selector?.value?.now === outbound?.code,
              },
              ...outbounds,
            ],
          };
        }
      }

      if (section.connection_type === 'vpn') {
        const outbound = proxies.find(
          (proxy) => proxy.code === `${section['.name']}-out`,
        );

        return {
          withTagSelect: false,
          code: outbound?.code || section['.name'],
          displayName: section['.name'],
          outbounds: [
            {
              code: outbound?.code || section['.name'],
              displayName: section.interface || outbound?.value?.name || '',
              latency: outbound?.value?.history?.[0]?.delay || 0,
              type: outbound?.value?.type || '',
              selected: true,
            },
          ],
        };
      }

      return {
        withTagSelect: false,
        code: section['.name'],
        displayName: section['.name'],
        outbounds: [],
      };
    });

  return {
    success: true,
    data,
  };
}
