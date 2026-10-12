import { Injectable, Logger, NestMiddleware } from '@nestjs/common';
import { trace } from '@opentelemetry/api';
import type { NextFunction, Request, Response } from 'express';

@Injectable()
export class RequestLoggingMiddleware implements NestMiddleware {
  private readonly logger = new Logger('HTTP');

  use(req: Request, res: Response, next: NextFunction): void {
    const start = performance.now();
    const traceId = trace.getActiveSpan()?.spanContext().traceId;

    res.on('finish', () => {
      const entry = {
        method: req.method,
        path: req.originalUrl.split('?')[0],
        status: res.statusCode,
        durationMs: Math.round(performance.now() - start),
        traceId,
      };

      if (res.statusCode >= 500) {
        this.logger.error(entry);
      } else if (res.statusCode >= 400) {
        this.logger.warn(entry);
      } else {
        this.logger.log(entry);
      }
    });

    next();
  }
}
