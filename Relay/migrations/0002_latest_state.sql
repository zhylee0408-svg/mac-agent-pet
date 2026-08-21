-- 存储每台设备最新的状态 envelope，供手机「拉取制」使用（GET /v1/devices/:id/latest）。
-- envelope 为端到端加密（X25519+AES-GCM，中继无法解密），落库仅为跨实例一致性。
ALTER TABLE routes ADD COLUMN last_state_envelope TEXT;
