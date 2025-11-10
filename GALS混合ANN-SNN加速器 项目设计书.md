### GALS混合ANN-SNN加速器 项目设计书 (最终版 - Q1.7全量化)

#### 1. 总体设计思想

本设计的核心思想是构建一个**算法-硬件协同设计**的异构处理引擎，使其硬件架构在数据流和计算范式上，精确映射软件模型中定义的混合计算特性。

本设计将实现一个**端到端的Q1.7（8位定点）量化方案**。ANN前端和SNN后端的所有权重、激活值和时间值都将在Q1.7格式下计算，以实现最低的资源占用和功耗。

软件模型呈现出两种截然不同的计算阶段：

1. **ANN前端**：一个处理密集像素流、具有复杂并行门控逻辑（`UltraLightweightGatedBlock`）的数据流阶段。
2. **SNN后端**：一个处理稀疏事件流、计算依赖于高维矩阵（`SpikingDense`）的事件驱动阶段。

为了在FPGA上以最高效率和最低功耗实现这种混合特性，我们将采用**GALS（全局异步，局部同步）**架构。

- **全局异步（Globally Asynchronous）**： 在顶层模块之间（例如`ANN_Engine`与`GALS_Encoder_Unit`之间），通信完全由**异步四相握手协议（Req/Ack）**驱动。数据的到达会“唤醒”下一个模块。没有数据时，模块自动停滞，其内部的局部时钟将被门控，从而实现接近零的动态功耗。这种方式天然地实现了事件驱动和系统级的背压（Backpressure）。
- **局部同步（Locally Synchronous）**： 在每一个复杂的功能模块内部（例如一个SNN处理单元或ANN的FSM），所有逻辑均由一个**局部同步时钟（local_clk）**驱动。这使我们能够安全、可靠、可预测地使用FPGA中的同步原语（如BRAM、DSP、同步计数器），规避了纯异步设计在综合、时序和验证上的巨大风险。

#### 2. 核心设计要点

1. **Q1.7 全量化**：硬件将*正确实现*端到端的Q1.7量化。`GALS_Encoder_Unit`将实现8位到8位的`t_i = 1.0 - x_q1.7`转换。`PE_GALS_Wrapper`将实现8位的`(tj - t_min) * kernel`计算。所有累加器（如`ACC_W`）将被优化为32位。
2. **O(1)事件处理**：SNN后端将被设计为一个最大64 PE的并行处理阵列。阵列由AER事件广播驱动，使其能够在`O(1)`（一个或几个`local_clk`周期）的恒定时间内，并行处理完一个输入脉冲对所有活动PE的贡献。
3. **流水线式融合**：为实现ANN `UltraLightweightGatedBlock`中的`main * channel * spatial`融合，`ULG_Coordinator`将采用`(A*B)*C`的计算顺序，以提升性能。
4. **精细功耗控制**：通过GALS的“计算完即休眠”特性。
   - **ANN端**：`ULG_Coordinator`将并行启动三个子模块，并在任何一个子模块拉高其`o_done`信号时，**立即关闭**该子模块的`clk_en`，使其进入休眠。
   - **SNN端**：`SNN_Engine` FSM将实现**层循环**。在计算`dense_2`（32 PE）时，未使用的32个PE（及关联的8个BRAM）将被**完全时钟门控**。在计算`dense_3`（3 PE）时，未使用的61个PE（及15个BRAM）将被时钟门控。
5. **鲁棒的接口设计**：
   - **多位总线**：所有多位总线（AER、像素流）的跨时钟域通信必须使用**数据保持（Data-Hold）四相握手**协议。
   - **并行Join**：所有需要等待`N`个并行事件完成的逻辑（如`GALS_Collector_Unit`）都*必须*使用**同步计数器**来实现，**禁止**使用高扇入的异步C-element。
6. **资源优化（SNN存储）**：为实现`dense_1`（64 PE）的`O(1)`读取，同时节省BRAM资源，我们将采用**宽BRAM（Wide BRAM Banking）方案。我们将使用16个32-bit宽**的双端口RAM（而不是64个8-bit RAM）。每个RAM在一个周期内可同时为4个PE提供权重。

#### 3. 顶层模块层次与数据流 (最终方案)

本设计采用**“ANN 2+1共享方案”**和**“SNN 16x4循环方案”**。

##### 模块层次结构 (最终方案)：

```
GALS_Accelerator_Top/
│
├── ANN_Engine/  (GALS 顶层FSM, 负责 C1 任务和 C2 启动)
│   │
│   ├── Hardware_Pool/
│   │   ├── SHARED_DW_UNIT  (depthwise_conv_unit)
│   │   └── SHARED_PW_UNIT  (pointwise_conv_unit)
│   │
│   ├── Feature_Map_Buffer_1W3R/ (1写, 3读 BRAM)
│   │
│   └── ULG_Coordinator/ (GALS 子FSM, 负责 C2 任务)
│       │
│       ├── Main_Path_Unit/ (P1)
│       ├── Channel_Gate_Unit/ (P2)
│       ├── Spatial_Gate_Unit/ (P3)
│       │   └── DEDICATED_DW_UNIT (depthwise_conv_unit)
│       │
│       └── Fusion_FSM/ (P4 - 融合逻辑)
│
├── GALS_Encoder_Unit (GALS Bridge, 8-bit to 8-bit)
│
└── SNN_Engine/ (GALS Master FSM, 负责 3 周期循环)
    │
    ├── SNN_Array_4PE [Array, 1..16] (16个4-PE阵列)
    │   ├── PE_GALS_Wrapper [Array, 1..4]
    │   └── GALS_Collector_4PE [1]
    │
    ├── SEE_Weight_RAM_32bit [Array, 1..16] (16个32-bit宽BRAM)
    │
    ├── Intermediate_Buffer_Encoder/ (FIFO, 用于层间缓冲)
    │
    └── ArgMax_Unit/ (32-bit input)
```

##### 总体数据流 (最终方案)：

数据流是一个由GALS FSM协调的、多阶段的GALS任务流：

1. **ANN C1 任务**：`ANN_Engine`的GALS FSM被`i_data_req`唤醒，进入“C1 任务”阶段。
2. **C1 资源分配**：`ANN_Engine` FSM **打开** `SHARED_DW_UNIT` 和 `SHARED_PW_UNIT` 的时钟门控（`clk_en=1`）。
3. **C1 计算**：`ANN_Engine` FSM（实现了C1的逻辑）从`Parameter_ROM`加载C1权重，驱动两个共享单元执行 `DSC_Module` 的计算（包含`Requantize`），并通过其写端口将结果（8-bit Q1.7）写入`Feature_Map_Buffer`。
4. **C1 任务结束/休眠**：C1 FSM拉高`c1_done`信号。`ANN_Engine`的GALS FSM检测到此信号，**关闭** `SHARED_DW_UNIT` 和 `SHARED_PW_UNIT` 的时钟门控（`clk_en=0`）。
5. **ANN C2 任务**：`ANN_Engine` FSM 立即**唤醒** `ULG_Coordinator` 子模块（设置 `ulg_clk_en=1` 和 `ulg_start=1`），进入“C2 任务”阶段。
6. **C2 并行启动**：`ULG_Coordinator`被唤醒，其FSM**并行启动**`Main_Path_Unit` (P1)、`Channel_Gate_Unit` (P2) 和 `Spatial_Gate_Unit` (P3)。
7. **C2 资源连接**：`ANN_Engine` 的顶层MUX将 `SHARED_DW_UNIT` 的控制权交给P1，`SHARED_PW_UNIT` 的控制权交给P2。P3使用其内部的`DEDICATED_DW_UNIT`。
8. **C2 精细门控**：P1, P2, P3 并行计算。当 `P1` 完成并拉高 `p1_done` 时，`ULG_Coordinator`**立即关闭** `P1` 的 `clk_en`（`ANN_Engine`继而关闭 `SHARED_DW_UNIT` 的 `clk_en`）。P2 和 P3 同理。
9. **C2 融合流**：`ULG_Coordinator`的 `Fusion_FSM`等待 `p1_done`, `p2_done`, `p3_done` 信号。全部完成后，它从三个BRAM读端口读取数据，执行 `(A*B)*C` 融合（8-bit Q1.7计算），并打包结果。
10. **GALS握手（C2 -> Encoder）**：`Fusion_FSM`将打包好的8-bit像素流（`o_encoder_data_flat`）放入寄存器，拉高 `o_encoder_req`。它**必须停滞（Stall）**，直到 `i_encoder_ack`返回高电平，才能拉低 `o_encoder_req` 并处理下一个像素。
11. **ANN 休眠**：当 `Fusion_FSM`完成所有像素的发送后，拉高 `ulg_done`。`ANN_Engine`FSM 收到此信号，返回 `S_IDLE` 状态，等待下一次 `i_data_req`。
12. **编码器（Q1.7 -> Q1.7时间）**：`GALS_Encoder_Unit`被 `o_encoder_req` 唤醒，接收8-bit Q1.7像素值 `x`。FSM循环320次，每次执行 `t_i = T_MAX_Q1.7 - ( (x - K_MIN_Q1.7) >> K_SHIFT)` 的8位定点运算，并广播8-bit的AER事件 `{addr: i, time: t_i}`。它必须等待`SNN_Engine`的`i_aer_ack`才能发送下一个事件。
13. **SNN 层同步循环 (Master FSM)**：`SNN_Engine`的Master FSM在`i_accelerator_start`后启动。
    - **周期 1 (dense_1, N=64)**：
      - Master FSM **唤醒所有16个** `SNN_Array_4PE` 模块。
      - `GALS_Encoder_Unit` 广播 `(t_i, addr_i)`。
      - 所有16个 `SEE_Weight_RAM` (32-bit宽) 被读取。`BRAM[j]` 从 `addr = i + 0` 处读出 `W[i, 4j..4j+3]`。
      - 所有64个PE并行计算 `(t_i - t_min_d1) * W`。
      - `GALS_Collector_Unit` 收集64个`done`信号，向`GALS_Encoder_Unit`发回`ack`。
      - Encoder完成后，Master FSM从所有64个PE中读出32-bit电位，送入`Intermediate_Buffer_Encoder`。
    - **周期 2 (dense_2, N=32)**：
      - Master FSM **只唤醒前8个** `SNN_Array_4PE` 模块。`Array[8]`到`Array[15]`保持休眠（`clk_en=0`）。
      - `Intermediate_Buffer_Encoder` 广播 `(t_k, addr_k)`。
      - 前8个BRAM从`addr = k + 320`（权重打包偏移量）处读取权重。
      - 32个PE并行计算。
      - ...结果被送入`Intermediate_Buffer_Encoder`。
    - **周期 3 (dense_3, N=3)**：
      - Master FSM **只唤醒第1个** `SNN_Array_4PE` 模块。
      - FSM设置 `Array[0]` 的 `pe_enable = 4'b0111`（只启动3个PE）。
      - `BRAM[0]` 从 `addr = m + 384` 处读取权重。
      - 3个PE并行计算。
    - **结束**：Master FSM从`Array[0]`读取3个32-bit电位，送入`ArgMax_Unit`，拉高`o_accelerator_done`，返回`S_IDLE`。

#### 4. 核心模块设计要求 (最终方案)

##### ANN前端

- **`ANN_Engine`**
  - **功能**：GALS 顶层协调器。实现“2+1共享方案”的总控制。
  - **要求**：1. GALS FSM。 2. 必须例化**1个`SHARED_DW_UNIT`和1个`SHARED_PW_UNIT`作为硬件池。 3. 必须例化 `ULG_Coordinator`和 `Feature_Map_Buffer_1W3R`。 4. 必须包含一个完整的C1任务FSM**（实现`DSC_Module`逻辑，包含`Requantize`）。 5. 必须实现顶层**MUX**，根据 GALS 任务阶段（C1 或 C2）将共享硬件的控制权交给 C1 FSM 或 `ULG_Coordinator`。 6. 必须实现两级时钟门控。
- **`ULG_Coordinator`**
  - **功能**：GALS 同步子模块。负责 C2 阶段的并行计算和融合。
  - **要求**：1. 由 `ANN_Engine`的 `i_clk_en` 和 `i_start` 信号驱动。 2. 必须**例化** `Main_Path_Unit`、`Channel_Gate_Unit` 和 `Spatial_Gate_Unit` 三个子模块。 3. 必须包含一个**完整的Fusion FSM**。 4. 必须实现对 P1, P2, P3 的**精细时钟门控**。 5. 必须向 `ANN_Engine`**输出** `o_p1_clk_en` 和 `o_p2_clk_en` 信号以控制共享硬件。 6. 必须正确实现与 `GALS_Encoder_Unit`的**四相GALS握手**（`req/ack`）。
- **`Main_Path_Unit` (P1)**
  - **功能**：实现 C2.1 `main_path`逻辑。
  - **要求**：1. 同步FSM子模块。 2. **禁止**例化 `conv` 单元。 3. 必须将 `conv` 接口（`o_conv_valid`...）作为**端口**暴露。 4. 内部例化 `line_buffer_3x3`阵列。 5. 包含一个用于存储结果的内部BRAM。
- **`Channel_Gate_Unit` (P2)**
  - **功能**：实现 C2.2 `channel_gate_path`逻辑。
  - **要求**：1. 同步FSM子模块。 2. **禁止**例化 `conv` 单元。 3. 必须将 `conv` 接口（`o_conv_valid`...）作为**端口**暴露。 4. 内部例化 `global_avg_pool_unit`和 `hardsigmoid_unit`阵列。 5. 包含一个用于存储结果的内部BRAM。
- **`Spatial_Gate_Unit` (P3)**
  - **功能**：实现 C2.3 `spatial_gate_path`逻辑。
  - **要求**：1. 同步FSM子模块。 2. **必须在内部例化**其专用的 `DEDICATED_DW_UNIT`（即 `depthwise_conv_unit`）。 3. 内部例化 `channel_wise_mean_unit`、`line_buffer_3x3` 和 `hardsigmoid_unit`。 4. 包含一个用于存储结果的内部BRAM。

##### 编码器

- **`GALS_Encoder_Unit` (Bridge)**
  - **功能**：实现 Q1.7 ANN激活值到 Q1.7 SNN脉冲时间的转换。
  - **要求**：1. GALS FSM。 2. 必须实现**8位定点运算**：`t_i = T_MAX_Q1.7 - ( (x - K_MIN_Q1.7) >> K_SHIFT)`。所有`K_`值均为硬件常量。 3. 必须过滤`t_i >= T_MAX_Q1.7`的事件。 4. 必须实现**数据保持（Data-Hold）四相握手**协议。

##### SNN后端

- **`SNN_Engine`**
  - **功能**：GALS Master FSM，实现层同步循环（`dense_1`, `dense_2`, `dense_3`）。
  - **要求**：1. 必须例化**16个`SNN_Array_4PE`和16个`SEE_Weight_RAM_32bit`**。 2. 必须实现3周期FSM，并通过**地址偏移**（权重打包）和**时钟门控**（门控`SNN_Array_4PE`）来实现资源复用。 3. 必须例化`Intermediate_Buffer_Encoder`（用于层间通信）和`ArgMax_Unit`。
- **`SNN_Array_4PE`**
  - **功能**：层次化的4-PE处理单元。
  - **要求**：1. 必须例化**4个`PE_GALS_Wrapper`和1个4输入`GALS_Collector_Unit`**。 2. 必须包含一个32-bit到4x 8-bit的权重**解包器**（Unpacker）。 3. 必须支持`pe_enable [3:0]`信号，以实现PE级的精细时钟门控。
- **`SEE_Weight_RAM_32bit`**
  - **功能**：存储SNN权重，支持加载和宽读取。
  - **要求**：1. 必须实现为**双端口RAM**（A口读，B口写）。 2. 读端口（A口）数据宽度必须为**32位**（`4 * DATA_W`）。 3. 写端口（B口）用于FSM加载权重。
- **`PE_GALS_Wrapper` (SNN处理单元)**
  - **功能**：处理一个8-bit AER事件对*一个*输出神经元的贡献。
  - **要求**：1. GALS FSM（异步唤醒，`local_clk`逻辑）。 2. 所有数据端口（`i_aer_time`, `i_bram_data`）均为**8-bit (Q1.7)**。 3. 累加器（`V_j_reg`）必须为**32-bit**（或24-bit）以防止溢出。 4. 必须接收8-bit的`i_t_min`和`i_t_max`（或等效）参数。 5. 必须实现`V_j += (i_aer_time - i_t_min) * i_bram_data`的8位定点乘加。
- **`GALS_Collector_Unit` (SNN收集器)**
  - **功能**：可靠地聚合`N`个PE的完成信号。
  - **要求**：1. GALS FSM。 2. 必须使用**同步计数器**（`N_done`）。 3. 必须实现**看门狗定时器（Watchdog Timer）**来检测PE死锁。
- **`ArgMax_Unit` (最终决策)**
  - **功能**：找出最终电位的索引。
  - **要求**：输入数据宽度必须为**32-bit**（匹配`PE_GALS_Wrapper`的累加器）。

#### 5. “异步功耗”的GALS实现机制 (最终方案)

- **`ANN_Engine`的功耗实现：**
  1. **默认休眠**：`ANN_Engine` FSM 处于 `S_IDLE`。`SHARED_DW_CLK_EN`, `SHARED_PW_CLK_EN`, `ULG_CLK_EN` 均为 0。
  2. **C1 唤醒**：`i_data_req` 到达。`ANN_Engine` FSM 进入 `S_C1_RUN`。
  3. `ANN_Engine` **唤醒** C1 任务所需的硬件：`SHARED_DW_CLK_EN <= 1`, `SHARED_PW_CLK_EN <= 1`。
  4. **C1 休眠**：C1 内部 FSM 完成，拉高 `c1_done`。`ANN_Engine` FSM 检测到 `c1_done`，进入 `S_C2_RUN`。
  5. `ANN_Engine` FSM **关闭** C1 硬件：`SHARED_DW_CLK_EN <= 0`, `SHARED_PW_CLK_EN <= 0`。
  6. **C2 唤醒**：`ANN_Engine` FSM **唤醒** `ULG_Coordinator`：`ULG_CLK_EN <= 1`, `ULG_START <= 1`。
  7. **C2 精细门控（上层）**：`ANN_Engine` 将共享硬件的时钟控制权**交给** `ULG_Coordinator`：
     - `SHARED_DW_CLK_EN <= ulg_p1_clk_en`
     - `SHARED_PW_CLK_EN <= ulg_p2_clk_en`
  8. **C2 精细门控（下层）**：`ULG_Coordinator` 内部并行启动 P1, P2, P3。当 P1 完成时，`ULG_Coordinator` 将其 `o_p1_clk_en` 拉低，`ANN_Engine` 随即将 `SHARED_DW_CLK_EN` 拉低，`SHARED_DW_UNIT` **休眠**。P2 和 P3 同理。
  9. **C2 休眠**：`ULG_Coordinator` 的 `Fusion_FSM` 完成 GALS 握手，拉高 `ulg_done`。`ANN_Engine` FSM 检测到此信号，进入 `S_IDLE`，并将 `ULG_CLK_EN` 置 0，`ULG_Coordinator` **休眠**。
- **`GALS_Encoder_Unit`的功耗实现：**
  1. 默认“休眠”（`clk_en=0`）。
  2. 被`ANN_Engine`（通过`ULG_Coordinator`）的`o_encoder_req`唤醒。
  3. FSM 计算8-bit `t_i`，过滤后，拉高`aer_req`并等待`aer_ack`。在等待期间，FSM处于*停滞（Stall）*状态。
  4. 收到`aer_ack`后，FSM 继续处理，直到`o_encoder_req`变低，它返回`IDLE`状态并“休眠”。
- **`SNN_Engine`的功耗实现（核心）**：
  1. **全局休眠**：在没有任务时，**整个SNN引擎处于“关闭”状态**。所有16个`SNN_Array_4PE`及其`PE`和`Collector`的`local_clk`均被门控（`clk_en=0`）。
  2. **周期 1 唤醒 (dense_1, N=64)**：`SNN_Engine` Master FSM **唤醒所有16个** `SNN_Array_4PE` 模块。
  3. **PE 事件唤醒**：AER事件 `aer_req` 到达，广播给所有64个PE，PE的FSM被唤醒并开始计算。
  4. **PE 计算与休眠**：每个`PE`的FSM仅运行几个`local_clk`周期（读RAM、计算），在发出`done_j_req`并收到`done_j_ack`后，**立即返回IDLE状态并自我关闭**。
  5. **周期 2 唤醒 (dense_2, N=32)**：Master FSM **只唤醒前8个** `SNN_Array_4PE` 模块。**`Array[8]`到`Array[15]`（32个PE及8个BRAM）保持在零动态功耗的休眠状态**。
  6. **周期 3 唤醒 (dense_3, N=3)**：Master FSM **只唤醒第1个** `SNN_Array_4PE` 模块，并设置 `pe_enable = 4'b0111`。**`Array[1]`到`Array[15]`（60个PE及15个BRAM）保持休眠**。
  7. **结果**：SNN引擎的功耗特性是“计算驱动”和“事件驱动”的结合。它只在计算时消耗功率，并且只为当前层所需的PE和BRAM供电，实现了最低的资源占用和动态功G耗。