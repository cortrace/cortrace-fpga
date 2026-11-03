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
  `[600, 1200] / MMCM_MULT` MHz。默认 16 对应 37.5 到 75 MHz。
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
TRACE_USE_MMCM=1 TRACE_MMCM_CLKIN_NS=18.0 OUTBIT=trace_ddr_stream_mmcm.bit \
  vivado -mode batch -source ../fpga_flow/build_trace_stream.tcl
```
- `TRACE_MMCM_MULT`（默认 16）和 `TRACE_MMCM_CLKIN_NS`（默认 22.727）要和目标的 TRACECLK
  匹配：VCO = 频率 × MULT 必须在 600 到 1200 MHz。
- MMCM 模式下构建脚本把 `trace_data_in` 到 IDDR 的时序检查关掉（`set_false_path`）：相位在
  运行时移动，STA 没法判断。采样是否正确靠相位扫描判断。
- 时序全部满足（WNS 0.12 ns，WHS 0.04 ns，v1.1.0 基础上）。
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
## 5. 实测（RT1176 EVK，cachecliff，每点抓 0.05 s）
"干净"指 `addr-nacc` 为 0 或接近 0，且 `lost-sync` 与 `resync(TraceOn)` 相当
（后者是 ETM 溢出，不是采样错误）。
| 引脚时钟 | 焊盘（时钟/数据） | 只用 IDELAY | MMCM 相位 |
|---|---|---|---|
| 44 MHz | 0x2 / 0x3 | tap 12 到 18 | -80 到 -20 步（约 -2.0 到 -0.5 ns）干净 |
| 53 MHz | 0x2 / 0x2 | 没有干净点（tap 31 最接近，addr-nacc 59） | -90 到 -50 步（约 -1.9 到 -1.1 ns）干净，中心约 -70 |
| 53 MHz | 0x3 / 0x3 | 没有 | 没有干净点 |
| 66 MHz | 0x2 / 0x2 | 解不出 | 没有干净点，addr-nacc 最低约 67 |
- 53 MHz 在 -70 步抓 0.3 s（timing 档）：`lost-sync=7`、`resync(TraceOn)=7`、`addr-nacc=0`。
  44 MHz 同样的抓取是 55 到 62。差异来自带宽，不是采样。
- 66 MHz 的有数据区间在 -210 和 +210 步附近重复出现，间隔和一个位时间（约 425 步）一致，
  说明相位移动是对的。66 MHz 一位只有 7.6 ns，焊盘慢转换的边沿占掉了大部分，
  眼图基本闭合，这是目标板和线的限制，相位调不出来。
- 步长随 VCO 变化：44 MHz 约 25.4 ps，52.8 MHz 约 21.1 ps，66 MHz 约 17.9 ps（M=16）。
## 6. 限制
- 一个比特流只覆盖一个频率范围（M=16：37.5 到 75 MHz）。要覆盖更宽需要 DRP 动态重配或者
  多个比特流。低于 37.5 MHz 时请用默认比特流，IDELAY 在那里已经够用。
- 相位范围 ±255 步。硬件在多大范围内保持单调我没有查证；实测在 44 到 66 MHz
  的一个位时间内行为合理。
- 失锁期间 MMCM 输出无效，抓到的字节作废，恢复后由解码器重新同步。
- STA 不检查输入时序（见 §3）。
- 目前相位靠手工扫描。`docs/02` 的自动校准设计（已提交，工作区里该文件被删了，未动）
  可以直接把 `set-phase` 当作旋钮。
## 7. 和 orbtrace 的关系
orbtrace 上游的 `trace/glue.py` 用 litex 的 `DDRInput`，以 TRACECLK 本身为时钟，没有 PLL、
MMCM、IDELAY 或相位调节（工作区 `orbcode/orbtrace` 里可以核对）。本项目早期的
`docs/history/proposals/35-上游极简采样链直接移植.md` 也是这样判断的，并提过"加一个 90° 相移
的采样 MMCM，但会有 gap 失锁问题"。本文的 `mmcm_phase_ctl` 就是在处理失锁与恢复。
