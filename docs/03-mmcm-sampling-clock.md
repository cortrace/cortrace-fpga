# MMCM 采样时钟：运行时可调相位
日期：2026-11-03
状态：已上板验证（i.MX RT1176 EVK，STM32H743 未复测）
默认比特流仍用 BUFIO 时钟加 IDELAY。本文的 MMCM 模式是编译时可选的另一个比特流，
给"数据与时钟同沿变化"的目标板使用，例如 i.MX RT1176。
---
## 1. 为什么需要
IDDR 在 TRACECLK 的两个沿各采一个半字节。IDELAY 只能把数据推迟最多约 2.4 ns
（32 档，每档约 78 ps）。RT1176 的数据在时钟沿之后 1.4 到 3 ns 才变化，采样点正好落在
跳变带里，要把它移到数据眼中间，需要移动半个位时间（33 MHz 时 7.6 ns，44 MHz 时 5.7 ns）。
IDELAY 够不到。MMCM 的精细移相每步是 VCO 周期的 1/56（VCO 700 MHz 时约 25 ps），
运行时可调，范围远大于 IDELAY。
## 2. 结构
```
TRACECLK ─IBUF─► MMCM ─CLKOUT0─► BUFG ─┬─► IDDR C（采样）
  (D17, MRCC)    │  ▲                   └─► trace_clk（后级 FIFO 写侧）
                 │  └ PSEN/PSINCDEC/PSDONE
                 └ LOCKED ─► mmcm_phase_ctl（ref_200m 域）◄─ CSR 0x14/0x15/0x16
```
- MMCM 的 D 为 1，倍频系数 `MMCM_MULT`，输出分频等于 `MMCM_MULT`，所以输出频率等于
  TRACECLK。VCO 必须在 600 到 1200 MHz，所以一个比特流只覆盖
  `[600, 1200] / MMCM_MULT` MHz。默认 14 对应 42.9 到 85.7 MHz，正好盖住 RT1176 的 44 到 66 MHz 和 H743 的 56 到 83 MHz。
- `mmcm_phase_ctl` 把主机写的目标相位（有符号 10 位，限幅 ±255 步）一步一步送到 MMCM，
  每步约 15 个 PSCLK（200 MHz）周期。它也负责锁定监督：
  - 上电时复位 MMCM。
  - 失锁后 `cur` 清零（MMCM 重新锁定时回到相位 0），锁定后自动走回目标。
  - 失锁超过约 5 ms 就复位 MMCM（时钟消失或变频）。
  - 主机写 CSR 0x16 可以强制复位。
- IDELAY 仍然在数据脚上，可以和 MMCM 相位叠加。
## 3. 构建
```bash
source <Vivado 2021.1>/settings64.sh
cd cortrace-fpga/build
TRACE_USE_MMCM=1 OUTBIT=trace_ddr_stream_mmcm.bit \
  vivado -mode batch -source ../fpga_flow/build_trace_stream.tcl
```
- `TRACE_MMCM_MULT`（默认 14）和 `TRACE_MMCM_CLKIN_NS`（默认 16.0）要和目标的 TRACECLK
  匹配：VCO = 频率 × MULT 必须在 600 到 1200 MHz。
- MMCM 模式下构建脚本把 `trace_data_in` 到 IDDR 的时序检查关掉（`set_false_path`）：相位在
  运行时移动，STA 没法判断。采样是否正确靠相位扫描判断。
- 时序全部满足（M=14：WNS 0.14 ns，WHS 0.03 ns，v1.1.0 基础上）。
- 用 `fpga_flash.sh --sram` 先试，断电后回到 flash 里的设计。
## 4. 控制与读出
| CSR | 作用 |
|---|---|
| 0x14 | 目标相位低 8 位（先写） |
| 0x15 | 目标相位 bit9:8，写入时生效 |
| 0x16 | 任意写：复位 MMCM |
| 读 0xFF95 | `{5'b0, PSDONE 超时, 忙, 已锁定}` |
| 读 0xFF96/0xFF97 | 已到达的相位（有符号 10 位） |
| 读 0xFF98 | 失锁次数（饱和到 255） |
FEATURES 的 bit6 表示比特流有这个功能。`dbg_regfile` 的 `trace_mmcm_locked` 和失锁计数也接到了
这个 MMCM。
主机命令：
```bash
cortrace fpga ctrl set-phase -70 --pin-mhz 52.8   # 等 MMCM 到位，重新武装抓取
cortrace fpga ctrl relock                          # 改了目标的 TRACECLK 频率后
cortrace fpga health                               # 显示锁定、相位和失锁次数
```
目标改了 TRACECLK 频率以后，MMCM 可能失锁，也可能没有失锁但相位关系变了，所以改频率后
先 `relock`，再重新扫相位。
## 5. 实测（RT1176 EVK，cachecliff）
判据：`E = max(0, lost-sync - resync(TraceOn)) + addr-nacc` 为 0 才算干净；ETM 溢出造成的
`lost-sync` 总和 `resync(TraceOn)` 一样多，不算采样错误。每点先丢一段再抓，0.05 s。
**不要把一次 0.3 s 抓取里 `addr-nacc=0` 当成"干净"**：同一个点重复抓会有几十的差别，这条
判据在本文早先的一版里用错过（见 §7）。
**排线 A（飞线）**：
| 引脚时钟 | 焊盘（时钟/数据） | 只用 IDELAY | MMCM 相位 |
|---|---|---|---|
| 44 MHz | 0x2 / 0x3 | tap 12 到 18 | -120 到 -50 步干净 |
| 53 MHz | 0x2 / 0x2 | 没有干净点 | 最好的点（-70 步）重复抓 0.3 s，`addr-nacc` 55 到 137，不干净 |
| 66 MHz | 0x2 / 0x2 | 解不出 | 没有干净点 |
**排线 B（EVK 一侧 R1881 到 R1885 换成 33 Ω，排线空脚接地）**，焊盘 0x2 / 0x2，M=14，
RAM 镜像（`make RAM=1`），coverage 档：
| 引脚时钟 | MMCM 相位（步） | 说明 |
|---|---|---|
| 44 MHz | -150 到 -30 干净 | 窗口下沿没扫到；XIP 镜像，timing 档 |
| 53 MHz | -190 到 -30 干净，-10 起失败 | 约 3.9 ns 宽；下沿没扫到 |
| 66 MHz | -110 到 -50 干净，-30 起失败 | 约 1.1 到 1.5 ns 宽 |
| 66 MHz，焊盘全 0x3 | 没有干净点 | 快转换在 66 MHz 反而更差 |
- 排线 B 把 53 MHz 从"没有干净点"变成"窗口约 4 ns"，66 MHz 从"解不出"变成"约 1.3 ns"。
  这是这几次测量里改善最大的一项。
- 66 MHz 在 timing 档、相位 -80 步，重复抓 0.3 s：一次 `addr-nacc=0`，一次 8，另外两次
  解码没有结果（目标那时可能没有产生 ETM 数据）。结论只能写到"窗口里大多干净"。
- 两个排线版本用的目标镜像不同（飞线时是 XIP，33 Ω 时 XIP 镜像因板子掉进 ROM 而改成 RAM
  镜像），ETM 流量不同，这里没有隔离这个变量。
- 步长随 VCO 变化（M=14）：44 MHz 约 29 ps，52.8 MHz 约 24 ps，66 MHz 约 19 ps。
### STM32H743 回归（MMCM 比特流 M=14 对默认比特流）
H743 跑 cachecliff 固件（`make CACHECLIFF=1`，`-DPLL_R_OVR` 和 `-DPLL_N_OVR` 改引脚时钟），
数据与时钟中心对齐。FPGA 是 SRAM 里的 MMCM 比特流，coverage 档，每点 0.05 s：
| 引脚时钟 | MMCM 相位（步）干净 |
|---|---|
| 56.25 MHz | -150 到 +100 |
| 75 MHz | -200 到 0（窗口中心约 -100，相位 0 在边缘） |
| 83.3 MHz | +50 到 +225 |
窗口都比 IDELAY 宽，但中心位置随频率变，要按频率扫相位，不能固定写 0。
**timing 档不如默认比特流**：83.3 MHz、timing 档、抓 0.3 s：
- 默认比特流（v1.1.0，IDELAY tap 15）：解出 322532 个 slice，`lost-sync=0`，`addr-nacc=0`，干净。
  coverage 档 tap 6 到 27 都干净。
- MMCM 比特流，相位 +140：四次里两次 `addr-nacc` 95 和 128、`lost-sync` 1147 和 2269，
  另外两次没有事件；相位 +100、+125 也没有事件。
同一个相位在 coverage 档干净，在 timing 档不干净。原因我没有查清（timing 档的数据量约
是 coverage 档的 4 倍，且带时间戳）。56 和 75 MHz 的 timing 档没有对比。
所以现阶段：H743 继续用默认比特流，MMCM 比特流给 RT1176。
## 6. 限制
- 一个比特流只覆盖一个频率范围（M=14：42.9 到 85.7 MHz）。DRP 动态改倍频不能和精细移相同时
  用（XAPP888 的参考设计不支持开了精细移相的输出）。低于 42.9 MHz 时请用默认比特流，
  IDELAY 在那里已经够用。
- 相位范围 ±255 步。硬件在多大范围内保持单调我没有查证；实测在 44 到 66 MHz
  的一个位时间内行为合理。
- 失锁期间 MMCM 输出无效，抓到的字节作废，恢复后由解码器重新同步。
- STA 不检查输入时序（见 §3）。
- 目前相位靠手工扫描。`docs/02` 的自动校准设计（已提交，工作区里该文件被删了，未动）
  可以直接把 `set-phase` 当作旋钮。
## 7. 更正记录
本文第一版写过"53 MHz 用 MMCM 干净"，依据是一次 0.3 s 抓取 `addr-nacc=0`。重复测量不成立
（M=14 和 M=16 一样，`addr-nacc` 59 到 137）。已按 §5 改正。
## 8. 和 orbtrace 的关系
orbtrace 上游的 `trace/glue.py` 用 litex 的 `DDRInput`，以 TRACECLK 本身为时钟，没有 PLL、
MMCM、IDELAY 或相位调节（工作区 `orbcode/orbtrace` 里可以核对）。本项目早期的
`docs/history/proposals/35-上游极简采样链直接移植.md` 也是这样判断的，并提过"加一个 90° 相移
的采样 MMCM，但会有 gap 失锁问题"。本文的 `mmcm_phase_ctl` 就是在处理失锁与恢复。
