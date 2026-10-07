import { EventEmitter } from 'node:events';
import { Logger } from '@nestjs/common';
import type { Request, Response } from 'express';
import { RequestLoggingMiddleware } from './request-logging.middleware.js';

function handle(status: number, headers: Record<string, string> = {}) {
  const req = {
    method: 'GET',
    originalUrl: '/users?email=ada@example.com',
    get: (name: string) => headers[name.toLowerCase()],
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

  it('includes the load balancer trace id', () => {
    handle(200, { 'x-amzn-trace-id': 'Root=1-67890abc-def' });

    expect(log).toHaveBeenCalledWith(
      expect.objectContaining({ traceId: 'Root=1-67890abc-def' }),
    );
  });
});
