### GALS混合ANN-SNN加速器 项目设计书





#### 1. 总体设计思想



本设计的核心思想是构建一个**算法-硬件协同设计**的异构处理引擎，使其硬件架构在数据流和计算范式上，精确映射软件模型中定义的混合计算特性。

软件模型呈现出两种截然不同的计算阶段：

1. **ANN前端**：一个处理密集像素流、具有复杂并行门控逻辑（`UltraLightweightGatedBlock`）的数据流阶段。
2. **SNN后端**：一个处理稀疏事件流、计算依赖于高维矩阵（`SpikingDense`）的事件驱动阶段。

为了在FPGA上以最高效率和最低功耗实现这种混合特性，我们将采用**GALS（全局异步，局部同步）**架构。

- 全局异步（Globally Asynchronous）：

  在顶层模块之间（例如ANN引擎与SNN引擎之间），通信完全由**异步四相握手协议（Req/Ack）**驱动。数据（无论是密集的像素流还是稀疏的AER事件）的到达会“唤醒”下一个模块。没有数据时，模块自动停滞，其内部的局部时钟将被门控，从而实现接近零的动态功耗。这种方式天然地实现了事件驱动和系统级的背压（Backpressure）。

- 局部同步（Locally Synchronous）：

  在每一个复杂的功能模块内部（例如一个SNN处理单元或ANN的融合协调器），所有逻辑均由一个**局部同步时钟（local_clk）**驱动一个有限状态机（FSM）。这使我们能够安全、可靠、可预测地使用FPGA中的同步原语（如BRAM、DSP、同步计数器），规避了纯异步设计在综合、时序和验证上的巨大风险。



#### 2. 核心设计要点



1. **架构与算法统一**：硬件将*正确实现*软件模型中的所有关键创新点。这包括为`UltraLightweightGatedBlock`构建一个三路并行的、时钟门控的处理单元，以及为`DivisionFreeAnnToSnnEncoder`实现基于CLZ（前导零计数）的`log2`动态缩放逻辑。
2. **O(1)事件处理**：SNN后端将被设计为一个全并行的处理阵列。阵列中的`N`个处理单元（PE）由AER事件广播驱动，使其能够在`O(1)`（一个或几个`local_clk`周期）的恒定时间内，并行处理完一个输入脉冲对所有`N`个输出神经元的贡献。
3. **流水线式融合**：为实现`UltraLightweightGatedBlock`中的`main * channel * spatial`融合，我们将采用“流水线式融合”设计。协调器FSM将采用`(A*B)*C`的计算顺序，将第一步乘法（A*B）的延迟隐藏在第三条路径（C）的计算时间中，以提升性能。
4. **精细功耗控制**：通过GALS的“计算完即休眠”特性。在`UltraLightweightGatedBlock`中，当`Main_Path`（A）和`Channel_Gate`（B）完成计算后，它们的`clk_en`将被立即关闭，使其进入零动态功耗状态，无需等待最慢的`Spatial_Gate`（C）完成。
5. **鲁棒的接口设计**：
   - **多位总线**：为防止多位数据（如AER事件）在异步边界采样时出现不一致，所有AER广播都必须使用**数据保持（Data-Hold）四相握手**协议。
   - **并行Join**：为防止高扇入（high fan-in）C-element带来的亚稳态和路由噩梦，所有需要等待`N`个并行事件完成的逻辑（如`GALS_Collector_Unit`）都*必须*使用**同步计数器**来实现。



#### 3. 顶层模块层次与数据流





##### 模块层次结构：



```
GALS_Accelerator_Top/
├── ANN_Engine/
│   ├── DSC_Module (C1)
│   └── ULG_Coordinator (C2 Wrapper)
│       ├── Main_Path_Unit (C2.1)
│       ├── Channel_Gate_Unit (C2.2)
│       └── Spatial_Gate_Unit (C2.3)
│
├── GALS_Encoder_Unit (Bridge)
│
└── SNN_Engine/
    ├── PE_GALS_Wrapper [Array, 1..N]
    ├── SEE_Weight_BRAM [Array, 1..N]
    └── GALS_Collector_Unit
```



##### 总体数据流：



1. **ANN数据流**：密集的像素流通过异步握手进入`DSC_Module` (C1)。C1处理后的数据流通过异步握手“唤醒”`ULG_Coordinator` (C2)。
2. **ULG并行流**：`ULG_Coordinator`的FSM被唤醒，它通过`clk_en`（时钟使能）“打开”其三个子模块（`Main`, `Channel`, `Spatial`），并广播输入数据。
3. **ULG融合流**：三个子模块并行计算。`ULG_Coordinator`的FSM以“流水线式”顺序收集`done`信号和结果（例如，等待A和B完成 -> 启动A*B的计算 -> 关闭A和B的时钟 -> 等待C和(A*B)完成 -> 启动(A*B)*C的计算 -> 关闭C的时钟）。
4. **编码器（密-疏转换）**：融合后的密集数据流通过异步握手进入`GALS_Encoder_Unit`。Encoder的FSM被唤醒，计算`t_i`，并过滤掉无效（`>= T_MAX`）的事件。
5. **SNN广播（AER总线）**：对于每个有效事件，`GALS_Encoder_Unit`将其`{addr, i, t_i}`数据放置在全局AER总线上，并拉高`aer_req`。它必须保持数据稳定并等待，直到`aer_ack`返回。
6. **SNN并行处理**：`aer_req`被广播给所有`N`个`PE_GALS_Wrapper`。所有PE同时被唤醒，锁存`data_bus`，并启动其内部的`local_clk` FSM。每个PE `j` 向其专属的`SEE_Weight_BRAM` `j` 发出同步读请求（地址为`i`），获取`W[i, j]`，执行乘加并更新`V_j_reg`。
7. **SNN收集与背压**：每个PE完成后，通过四相握手（`done_j_req`）通知`GALS_Collector_Unit`。Collector的FSM使用同步计数器统计`done`信号。当计数器达到`N`时，它向`GALS_Encoder_Unit`发回`aer_ack`脉冲。这个`aer_ack`的延迟（即SNN的处理时间）自动实现了对Encoder乃至ANN前端的流控（背压）。



#### 4. 核心模块设计要求





##### ANN前端



- **`DSC_Module` (C1)**
  - **功能**：实现标准的深度可分离卷积。
  - **要求**：1. GALS FSM（异步握手接口，`local_clk` FSM逻辑）。 2. 内部实现为标准的流式同步流水线（LineBuffer -> DW Conv -> PW Conv -> Requant）。
- **`ULG_Coordinator` (C2父模块)**
  - **功能**：协调`UltraLightweightGatedBlock`的并行计算与流水线融合。
  - **要求**：1. GALS FSM。 2. 必须通过`clk_en`信号管理三个子模块的**精细时钟门控**，实现“计算完即休眠”的功耗特性。 3. 必须实现**流水线式融合**（`(A*B)*C`），以隐藏部分乘法延迟。 4. 必须使用同步乘法器阵列（DSP）进行融合。
- **`Main/Channel/Spatial_Path_Unit` (C2子模块)**
  - **功能**：分别实现`UltraLightweightGatedBlock`中定义的三条独立计算路径。
  - **要求**：1. 必须是纯**同步**FSM模块，其时钟由`ULG_Coordinator`通过`clk_en`门控。 2. `Channel`和`Spatial`模块必须正确实现`HardSigmoid`的**定点位移逻辑**（例如`(x >> 3) + 0.5`）。 3. 完成后必须拉高一个电平`done`信号，直到被`ULG_Coordinator`复位。



##### 编码器



- **`GALS_Encoder_Unit` (Bridge)**
  - **功能**：实现`DivisionFreeAnnToSnnEncoder`逻辑，作为GALS桥梁。
  - **要求**：1. GALS FSM。 2. 必须使用**同步CLZ（前导零计数）和桶形移位器（Barrel Shifter）来实现`log2`动态缩放。 3. 必须过滤`t_i >= T_MAX`的事件。 4. AER总线接口必须实现数据保持（Data-Hold）四相握手**协议。



##### SNN后端



- **`PE_GALS_Wrapper` (SNN处理单元)**
  - **功能**：`O(1)`处理一个AER事件对*一个*输出神经元的贡献。
  - **要求**：1. GALS FSM（异步唤醒，`local_clk`逻辑）。 2. 必须依赖Encoder的“Data-Hold”协议来安全锁存`data_bus`，**禁止**对多位总线进行逐位异步采样。 3. 必须使用`local_clk`对其专属的BRAM执行**同步读**。 4. 必须使用`local_clk`和DSP资源执行同步乘加。 5. 与Collector的接口必须是**四相握手**（`done_j_req`/`i_done_ack_j`），**禁止**使用短脉冲。
- **`SEE_Weight_BRAM` (SNN权重内存)**
  - **功能**：存储SNN权重，支持`O(1)`并行访问。
  - **要求**：1. 必须实现为**`OUT_NEURONS`个独立的同步BRAM**（全复制模式）。 2. 每个BRAM `j` 存储`W[all_i, j]`列向量。 3. 必须提供一个参数化选项，以支持部分复制（Banking）作为资源受限时的备用方案。
- **`GALS_Collector_Unit` (SNN收集器)**
  - **功能**：可靠地聚合所有PE的完成信号，并管理全局`aer_ack`。
  - **要求**：1. GALS FSM。 2. **禁止**使用高扇入异步C-element。 3. 必须使用**四相握手**轮询`done_j_req`信号。 4. 必须使用`local_clk`驱动一个**同步计数器**（`N_done`）。 5. 计数器满`OUT_NEURONS`时，生成`aer_ack`脉冲并清零计数器。 6. 必须实现一个**看门狗定时器（Watchdog Timer）**来检测PE死锁或超时，并输出`error`信号。
- **`ArgMax_Unit` (最终决策)**
  - **功能**：从SNN最后一层（例如SNN3）的`PE`阵列中读取最终的电位，并找出最大值的索引。
  - **要求**：1. 由`GALS_Collector_Unit`的`aer_ack`（或一个专用的`layer_done`信号）触发。 2. 必须实现为树状或流水线式的同步比较器，以在几个`local_clk`周期内得出结果。

------



#### 5. “异步功耗”的GALS实现机制



本节专门阐述架构如何实现**“模块在不工作时一定要关闭，不要消耗功耗”**这一核心异步目标。

我们不使用无时钟电路，而是使用**异步握手**作为*触发器*，来控制**局部同步FSM**的**精细时钟门控（`clk_en`）**。

- **`ANN_Engine`的功耗实现：**
  1. `DSC_Module` (C1) 和 `ULG_Coordinator` (C2) 的`local_clk`在顶层被门控。
  2. 当全局输入流的`data_req`到达C1时，C1的`clk_en`被拉高，C1被“唤醒”并开始计算。
  3. C1完成后，通过`data_req`唤醒`ULG_Coordinator`，然后C1的`clk_en`被拉低，C1“休眠”。
  4. `ULG_Coordinator`（C2）被唤醒（`clk_en=1`），它进而通过`clk_en`唤醒其三个子模块（`Main`, `Channel`, `Spatial`）。
  5. **精细门控**：当`Main_Path_Unit`（假设最快）完成计算并拉高`main_path_done`时，`ULG_Coordinator`的FSM**立即将`main_path_clk_en`置为0**。`Main_Path_Unit`模块被“关闭”并停止消耗功耗，即使`Channel`和`Spatial`模块仍在全速运行。
  6. 所有计算和融合完成后，`ULG_Coordinator`通过`data_req`唤醒`Encoder`，然后`ULG_Coordinator`自身的`clk_en`被拉低，整个ANN引擎“休眠”。
- **`GALS_Encoder_Unit`的功耗实现：**
  1. 默认“休眠”（`clk_en=0`）。
  2. 被`ULG_Coordinator`的`data_req`唤醒（`clk_en=1`）。
  3. FSM计算`t_i`，过滤后，拉高`aer_req`并等待`aer_ack`。在等待期间，FSM处于*停滞（Stall）*状态，只消耗极低的功耗。
  4. 收到`aer_ack`后，FSM继续处理，直到输入数据流耗尽，它返回`IDLE`状态并“休眠”（`clk_en=0`）。
- **`SNN_Engine`的功耗实现（核心）**：
  1. **全局休眠**：在没有AER事件时，**整个SNN引擎处于“关闭”状态**。所有`PE_GALS_Wrapper`和`GALS_Collector_Unit`的`local_clk`均被门控（`clk_en=0`）。
  2. **事件唤醒**：`GALS_Encoder_Unit`拉高`aer_req`。
  3. **PE阵列唤醒**：`aer_req`信号被广播，它**同时将所有`N`个`PE`的`clk_en`拉高**，唤醒它们的FSM。
  4. **Collector唤醒**：`PE`完成计算后发出的`done_j_req`信号（通常是第一个到达的）将**唤醒`GALS_Collector_Unit`**（拉高其`clk_en`）。
  5. **计算与休眠**：
     - 每个`PE`的FSM仅运行几个`local_clk`周期（锁存、读BRAM、计算），在发出`done_j_req`并收到`done_j_ack`后，**立即返回IDLE状态并自我关闭（`clk_en=0`）**。
     - `Collector`的FSM在收集完`N`个`done`信号并发回`aer_ack`后，**立即返回IDLE状态并自我关闭（`clk_en=0`）**。
  6. **结果**：SNN引擎的功耗特性是完美的“事件驱动”。它仅在处理AER事件的几个时钟周期内消耗功率，其余时间（即使是在两个AER事件之间）都处于零动态功耗的休眠状态。