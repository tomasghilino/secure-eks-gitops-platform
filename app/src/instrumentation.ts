// loaded with `node --import` before the app, so every library is patched before it is first imported
import { register } from 'node:module';
import { metrics } from '@opentelemetry/api';
import { PrometheusExporter } from '@opentelemetry/exporter-prometheus';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { registerInstrumentations } from '@opentelemetry/instrumentation';
import {
  ExpressInstrumentation,
  ExpressLayerType,
} from '@opentelemetry/instrumentation-express';
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import { PgInstrumentation } from '@opentelemetry/instrumentation-pg';
import { RuntimeNodeInstrumentation } from '@opentelemetry/instrumentation-runtime-node';
import {
  detectResources,
  envDetector,
  resourceFromAttributes,
} from '@opentelemetry/resources';
import { MeterProvider } from '@opentelemetry/sdk-metrics';
import {
  BatchSpanProcessor,
  NodeTracerProvider,
} from '@opentelemetry/sdk-trace-node';
import {
  ATTR_SERVICE_NAME,
  ATTR_URL_QUERY,
} from '@opentelemetry/semantic-conventions';

const NOISE = ['/health', '/health/ready', '/metrics'];

if (process.env.OTEL_SDK_DISABLED !== 'true') {
  // express is imported from nest's esm code, which can only be patched through this loader hook
  register('@opentelemetry/instrumentation/hook.mjs', import.meta.url);

  const resource = resourceFromAttributes({ [ATTR_SERVICE_NAME]: 'api' }).merge(
    detectResources({ detectors: [envDetector] }),
  );

  const meterProvider = new MeterProvider({
    resource,
    readers: [new PrometheusExporter({ port: 9464 })],
  });
  metrics.setGlobalMeterProvider(meterProvider);

  // traces are only exported when a collector is configured; the provider is still
  // registered because the request context it carries also labels the http metrics
  const tracerProvider = new NodeTracerProvider({
    resource,
    spanProcessors: process.env.OTEL_EXPORTER_OTLP_ENDPOINT
      ? [new BatchSpanProcessor(new OTLPTraceExporter())]
      : [],
  });
  tracerProvider.register();

  registerInstrumentations({
    instrumentations: [
      new HttpInstrumentation({
        ignoreIncomingRequestHook: (req) =>
          NOISE.includes(req.url?.split('?')[0] ?? ''),
        // same rule as the request log: query strings can carry personal data
        requestHook: (span, req) => {
          if ('url' in req && req.url?.includes('?')) {
            span.setAttribute(ATTR_URL_QUERY, 'REDACTED');
          }
        },
      }),
      new ExpressInstrumentation({
        ignoreLayersType: [ExpressLayerType.MIDDLEWARE],
      }),
      new PgInstrumentation(),
      new RuntimeNodeInstrumentation(),
    ],
  });

  // nest closes the app on these signals and then raises them again, which ends the process
  for (const signal of ['SIGTERM', 'SIGINT']) {
    process.once(signal, () => {
      void Promise.all([tracerProvider.shutdown(), meterProvider.shutdown()]);
    });
  }
}
