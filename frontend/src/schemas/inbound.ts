import { z } from 'zod';

export const SlimInboundSchema = z
  .object({
    id: z.number(),
    protocol: z.string(),
  })
  .loose();

export const SlimInboundListSchema = z.array(SlimInboundSchema);

export const InboundDetailSchema = z
  .object({
    id: z.number(),
    protocol: z.string(),
  })
  .loose();

export const LastOnlineMapSchema = z.record(z.string(), z.number());

export const InboundFormSchema = z.object({
  remark: z.string(),
  enable: z.boolean(),
  port: z
    .number({ error: 'pages.inbounds.toasts.portRequired' })
    .int()
    .min(1, 'pages.inbounds.toasts.portRange')
    .max(65535, 'pages.inbounds.toasts.portRange'),
  listen: z.string(),
  protocol: z.string().min(1, 'pages.inbounds.toasts.protocolRequired'),
  // Scales Xray-reported traffic deltas before they enter client_traffics /
  // inbound up-down. 1.0 = identity (legacy behaviour). Backend clamps to
  // [0.1, 100] so an out-of-range value here is corrected on the next save.
  trafficMultiplier: z
    .number()
    .min(0.1, 'pages.inbounds.toasts.trafficMultiplierRange')
    .max(100, 'pages.inbounds.toasts.trafficMultiplierRange'),
});

export type SlimInbound = z.infer<typeof SlimInboundSchema>;
export type InboundDetail = z.infer<typeof InboundDetailSchema>;
export type LastOnlineMap = z.infer<typeof LastOnlineMapSchema>;
export type InboundFormValues = z.infer<typeof InboundFormSchema>;
