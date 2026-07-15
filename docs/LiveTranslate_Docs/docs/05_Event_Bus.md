# Event Bus

Only immutable facts are published. Commands call services directly. Raw audio remains on the session-local path. Realtime subscribers use bounded mailboxes; durable subscribers suspend producers instead of dropping events.
