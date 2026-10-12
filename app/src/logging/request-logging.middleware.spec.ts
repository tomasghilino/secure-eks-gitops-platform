import { EventEmitter } from 'node:events';
import { Logger } from '@nestjs/common';
import { trace } from '@opentelemetry/api';
import type { Request, Response } from 'express';
import { RequestLoggingMiddleware } from './request-logging.middleware.js';

function handle(status: number) {
  const req = {
    method: 'GET',
    originalUrl: '/users?email=ada@example.com',
  } as unknown as Request;
  const res = Object.assign(new EventEmitter(), {
    statusCode: status,
  }) as unknown as Response;
  const next = vi.fn();

  new RequestLoggingMiddleware().use(req, res, next);
  res.emit('finish');

  return next;
}

describe('RequestLoggingMiddleware', () => {
  const log = vi.spyOn(Logger.prototype, 'log').mockReturnValue();
  const warn = vi.spyOn(Logger.prototype, 'warn').mockReturnValue();
  const error = vi.spyOn(Logger.prototype, 'error').mockReturnValue();

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterAll(() => {
    vi.restoreAllMocks();
  });

  it('logs successful requests without the query string', () => {
    const next = handle(200);

    expect(next).toHaveBeenCalledOnce();
    expect(log).toHaveBeenCalledWith({
      method: 'GET',
      path: '/users',
      status: 200,
      durationMs: expect.any(Number),
      traceId: undefined,
    });
  });

  it('logs client errors as warnings', () => {
    handle(404);

    expect(warn).toHaveBeenCalledWith(expect.objectContaining({ status: 404 }));
    expect(log).not.toHaveBeenCalled();
  });

  it('logs server errors as errors', () => {
    handle(500);

    expect(error).toHaveBeenCalledWith(
      expect.objectContaining({ status: 500 }),
    );
  });

  it('includes the trace id of the request span', () => {
    vi.spyOn(trace, 'getActiveSpan').mockReturnValueOnce(
      trace.wrapSpanContext({
        traceId: '4bf92f3577b34da6a3ce929d0e0e4736',
        spanId: '00f067aa0ba902b7',
        traceFlags: 1,
      }),
    );

    handle(200);

    expect(log).toHaveBeenCalledWith(
      expect.objectContaining({ traceId: '4bf92f3577b34da6a3ce929d0e0e4736' }),
    );
  });
});
