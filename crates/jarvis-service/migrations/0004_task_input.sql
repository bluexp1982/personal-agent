-- M4：worker 执行任务需要拿到创建时的参数（例如 trip-plan 的 submit 开关）。
-- M3 只把 input 用于展示语义，未落库；这里补上，执行器才能把原始输入下发给 worker。
ALTER TABLE tasks ADD COLUMN input_json TEXT;
