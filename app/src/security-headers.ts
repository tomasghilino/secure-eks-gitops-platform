import type { INestApplication } from '@nestjs/common';
import helmet from 'helmet';

export function applySecurityHeaders(app: INestApplication): void {
  app.use(helmet());
}
