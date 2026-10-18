import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const output = fileURLToPath(new URL('../.cache/mihomo', import.meta.url));
const source = fileURLToPath(new URL('../../../go_core/third_party/mihomo/', import.meta.url));
await mkdir(fileURLToPath(new URL('../.cache/', import.meta.url)), { recursive: true });
// This is Veer's modified local mirror, not an official release binary.
const child = spawn('go', ['build', '-ldflags', '-X github.com/metacubex/mihomo/constant.Version=veer-editor-local-mirror -X github.com/metacubex/mihomo/constant.BuildTime=local', '-o', output, '.'], { cwd: source, stdio: 'inherit' });
child.on('error', () => { console.error('需要安装 Go 才能构建 Mihomo 校验器；也可设置 MIHOMO_BIN 使用已有核心。'); process.exitCode = 1; });
child.on('close', code => { process.exitCode = code ?? 1; if (code === 0) console.log(`已构建本地 mirror 校验器：${output}`); });
