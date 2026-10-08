import { z } from 'zod';

export const createUserSchema = z.strictObject({
  name: z.string().trim().min(1).max(100),
  email: z.email().max(254),
});

export type CreateUserInput = z.infer<typeof createUserSchema>;

export const userIdSchema = z.uuid();

export const listUsersQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

export type ListUsersQuery = z.infer<typeof listUsersQuerySchema>;
