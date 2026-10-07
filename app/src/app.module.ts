import {
  MiddlewareConsumer,
  Module,
  NestModule,
  StandardSchemaValidationPipe,
} from '@nestjs/common';
import { APP_PIPE } from '@nestjs/core';
import { HealthModule } from './health/health.module.js';
import { RequestLoggingMiddleware } from './logging/request-logging.middleware.js';
import { UsersModule } from './users/users.module.js';

@Module({
  imports: [HealthModule, UsersModule],
  providers: [{ provide: APP_PIPE, useClass: StandardSchemaValidationPipe }],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer): void {
    consumer
      .apply(RequestLoggingMiddleware)
      .exclude('health')
      .forRoutes('{*path}');
  }
}
