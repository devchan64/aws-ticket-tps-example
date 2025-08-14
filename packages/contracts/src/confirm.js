import { Type } from "@sinclair/typebox";

export const ErrorResponse = Type.Object({
  error: Type.String(),
  message: Type.Optional(Type.String())
});

export const IdempotencyHeader = Type.Object({
  "idempotency-key": Type.String({ minLength: 8 })
});

export const PaymentIntentBody = Type.Object({
  userId: Type.String(),
  eventId: Type.String(),
  seatIds: Type.Array(Type.String(), { minItems: 1 })
});
export const PaymentIntentResponse = Type.Object({
  intentId: Type.String(),
  amount: Type.Integer()
});

export const CommitBody = Type.Object({
  intentId: Type.String(),
  eventId: Type.String(),
  seatIds: Type.Array(Type.String(), { minItems: 1 }),
  userId: Type.String()
});
export const CommitAcceptedResponse = Type.Object({
  accepted: Type.Boolean(),
  status: Type.Literal("PROCESSING"),
  idem: Type.String()
});

export const StatusQuery = Type.Object({ idem: Type.String() });
export const StatusResponse = Type.Object({
  order: Type.Union([Type.Null(), Type.Object({}, { additionalProperties: true })]),
  payment: Type.Union([Type.Null(), Type.Object({}, { additionalProperties: true })])
});

export const CommitSqsMessage = Type.Object({
  type: Type.Literal("COMMIT_ORDER"),
  payload: CommitBody,
  idem: Type.String()
});
