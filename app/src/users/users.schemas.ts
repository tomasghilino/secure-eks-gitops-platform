import { z } from 'zod';

export const createUserSchema = z.strictObject({
  name: z.string().trim().min(1).max(100),
  email: z.email().max(254),
});

export type CreateUserInput = z.infer<typeof createUserSchema>;

export const userIdSchema = z.uuid();
