import os
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader
import numpy as np
from typing import Dict, Union, List, Optional, Tuple, Any
import time
import copy
import argparse # 用于接收模型路径
from scipy.io import loadmat
from sklearn.model_selection import train_test_split
from torch.optim.lr_scheduler import CosineAnnealingLR
# --- 必需：从你的项目中导入所有相关的定义 ---

# 1. 从 TTFS.py 导入
from model.TTFS import SNNModel, SpikingDense, DivisionFreeAnnToSnnEncoder


class DepthwiseSeparableConv(nn.Module):
    """
    支持步长的深度可分离卷积模块。
    """
    def __init__(self, in_channels, out_channels, kernel_size, stride=1):
        super().__init__()
        padding = (kernel_size - 1) // 2
        self.depthwise = nn.Conv2d(in_channels, in_channels, kernel_size=kernel_size, stride=stride, padding=padding, groups=in_channels)
        self.pointwise = nn.Conv2d(in_channels, out_channels, kernel_size=1)
    def forward(self, x):
        return self.pointwise(self.depthwise(x))

class HardSigmoid(nn.Module):
    def __init__(self, inplace=False):
        super(HardSigmoid, self).__init__()
    def forward(self, x):
        return torch.clamp(x * 0.125 + 0.5, 0.0, 1.0)

class UltraLightweightGatedBlock(nn.Module):
    """
    主路径(DWConv) * 通道门(AvgPool+Conv1d) * 空间门(Mean+Conv2d)
    """
    def __init__(self, in_channels, out_channels, kernel_size):
        super().__init__()
        if in_channels != out_channels:
            raise ValueError("此轻量块的输入和输出通道必须相同。")
        
        padding = (kernel_size - 1) // 2
        
        self.main_path = nn.Sequential(
            nn.Conv2d(in_channels, in_channels, kernel_size=kernel_size, stride=1, padding=padding, groups=in_channels)
        )
        
        self.channel_gate_path = nn.Sequential(
            nn.AdaptiveAvgPool2d(1), # (B, C, 1, 1)
            nn.Conv2d(in_channels, in_channels, kernel_size=1), # 等效于 Linear(C, C)
            HardSigmoid()
        )
        
        self.spatial_gate_path = nn.Sequential(
            nn.Conv2d(1, 1, kernel_size=kernel_size, stride=1, padding=padding),
            HardSigmoid()
        )
            
        self.final_act = nn.Sequential(
            nn.BatchNorm2d(out_channels),
            nn.ReLU(inplace=True)
        )

    def forward(self, x):
        main_out = self.main_path(x)
        channel_gate = self.channel_gate_path(x)
        spatial_in = torch.mean(x, dim=1, keepdim=True)
        spatial_gate = self.spatial_gate_path(spatial_in)
        fused = main_out * channel_gate * spatial_gate
        return self.final_act(fused)

# --- 复制 train.py 中的数据加载和评估函数 ---

def load_features_from_mat(feature_dir: str) -> Tuple[np.ndarray, np.ndarray]:
    fpath = os.path.join(feature_dir, "all_features_lds_smoothed.mat")
    if not os.path.exists(fpath):
        raise FileNotFoundError(f"Data file not found: {fpath}")
    mat_data = loadmat(fpath)
    combined_features = mat_data['features'].astype(np.float32)
    combined_labels = mat_data['labels'].flatten()
    label_mapping = {-1: 0, 0: 1, 1: 2}
    valid_labels_indices = np.isin(combined_labels, list(label_mapping.keys()))
    features_filtered = combined_features[valid_labels_indices]
    labels_mapped = np.array([label_mapping[lbl] for lbl in combined_labels[valid_labels_indices]], dtype=np.int64)
    return features_filtered, labels_mapped

class NumericalEEGDataset(Dataset):
    def __init__(self, features: torch.Tensor, labels: np.ndarray):
        self.features = features.to(dtype=torch.float32)
        self.labels = torch.tensor(labels, dtype=torch.long)
    def __len__(self) -> int: return len(self.labels)
    def __getitem__(self, idx: int) -> Tuple[torch.Tensor, torch.Tensor]:
        return self.features[idx], self.labels[idx]

def evaluate_model(model: SNNModel, dataloader: DataLoader, criterion: nn.Module, device: torch.device) -> Tuple[float, float, List, List]:
    # (此函数从 train.py 复制而来，无需修改)
    model.eval(); running_loss, correct_predictions, total_samples = 0.0, 0, 0; all_labels, all_preds = [], []
    with torch.no_grad():
        for features, labels in dataloader:
            features, labels = features.to(device), labels.to(device)
            outputs, _ = model(features)
            loss = criterion(outputs, labels); running_loss += loss.item() * features.size(0)
            _, predicted = torch.max(outputs.data, 1); correct_predictions += (predicted == labels).sum().item()
            total_samples += labels.size(0); all_labels.extend(labels.cpu().numpy()); all_preds.extend(predicted.cpu().numpy())
    return running_loss / total_samples, correct_predictions / total_samples, all_labels, all_preds

# --- 【新增】Q1.7 量化模拟函数 ---

def quantize_q1_7(x: torch.Tensor) -> torch.Tensor:
    """
    将浮点张量模拟量化为 Q1.7 格式 (-1.0 to 127/128)。
    """
    scale = 128.0 # 2^7
    scaled_x = x * scale
    rounded_x = torch.round(scaled_x)
    clamped_x = torch.clamp(rounded_x, -128.0, 127.0)
    dequantized_x = clamped_x / scale
    return dequantized_x

def apply_weight_quantization(model: nn.Module):
    """
    遍历模型，将所有 'weight' 和 'kernel' 参数应用 Q1.7 量化。
    """
    with torch.no_grad():
        for name, param in model.named_parameters():
            if param.requires_grad and ('weight' in name or 'kernel' in name):
                # 原地更新参数
                param.data.copy_(quantize_q1_7(param.data))

# --- 【新增】用于 QAT 微调的训练函数 ---

def train_epoch_finetune(model: SNNModel, dataloader: DataLoader, criterion: nn.Module, optimizer: optim.Optimizer, device: torch.device, epoch: int, gamma_ttfs: float, t_min_input: float, t_max_input: float) -> Tuple[float, float]:
    """
    用于 QAT 微调的训练循环。
    关键区别：在 optimizer.step() 之后立即应用权重 Q1.7 量化。
    (此函数基于 train.py 中的 train_epoch 修改而来)
    """
    model.train()
    running_loss, correct_predictions, total_samples = 0.0, 0, 0
    
    for features, labels in dataloader:
        features, labels = features.to(device), labels.to(device)
        
        # 前向传播（使用上一轮量化后的权重）
        outputs, min_ti_list = model(features)
        
        loss = criterion(outputs, labels)
        
        # 反向传播和优化
        optimizer.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
        optimizer.step() # 此时权重是 float32

        # --- 【关键新增】 ---
        # 立即将更新后的 float32 权重投影回 Q1.7 格式
        apply_weight_quantization(model)
        # --- 【新增结束】 ---

        # (SNN 时间参数的更新逻辑保持不变)
        with torch.no_grad():
            snn_input_t_max = t_max_input
            for layer in model.layers_list:
                if isinstance(layer, DivisionFreeAnnToSnnEncoder): snn_input_t_max = layer.t_max; break
            current_t_min_layer = torch.tensor(snn_input_t_max, dtype=torch.float32, device=device)
            t_min_prev_layer = torch.tensor(t_min_input, dtype=torch.float32, device=device)
            k = 0
            for layer in model.layers_list:
                if isinstance(layer, SpikingDense):
                    if not layer.outputLayer:
                        min_ti_for_layer = min_ti_list[k] if k < len(min_ti_list) else None
                        # ... (SNN时间更新逻辑) ...
                        base_interval = torch.tensor(1.0, dtype=torch.float32, device=device)
                        new_t_max_layer = current_t_min_layer + base_interval
                        if min_ti_for_layer is not None:
                            positive_spike_times = min_ti_for_layer[min_ti_for_layer < layer.t_max]
                            if positive_spike_times.numel() > 0:
                                earliest_spike = torch.min(positive_spike_times)
                                if layer.t_max > earliest_spike:
                                    dynamic_term = gamma_ttfs * (layer.t_max - earliest_spike)
                                    new_t_max_layer = current_t_min_layer + torch.maximum(base_interval, dynamic_term)
                                    new_t_max_layer = torch.clamp(new_t_max_layer, max=current_t_min_layer + 100.0)
                        k += 1
                    else: new_t_max_layer = current_t_min_layer + 1.0
                    layer.set_time_params(t_min_prev_layer, current_t_min_layer, new_t_max_layer)
                    t_min_prev_layer = current_t_min_layer.clone(); current_t_min_layer = new_t_max_layer.clone()
        
        running_loss += loss.item() * features.size(0)
        _, predicted = torch.max(outputs.data, 1)
        correct_predictions += (predicted == labels).sum().item(); total_samples += labels.size(0)
        
    return running_loss / total_samples, correct_predictions / total_samples

# --- 【新增】模型构建函数 ---
def build_model(config: Dict) -> SNNModel:
    """
    根据配置构建 SNN 模型。
    (此逻辑从 train.py 的 run_training_session 中提取)
    """
    model = SNNModel()
    in_channels = 4
    ann_layers = []
    
    CONV_CHANNELS_CONFIG = config['CONV_CHANNELS']
    CONV_KERNEL_SIZE_PARAM = config['CONV_KERNEL_SIZE']
    HIDDEN_UNITS_1 = config['HIDDEN_UNITS_1']
    HIDDEN_UNITS_2 = config['HIDDEN_UNITS_2']
    DROPOUT_RATE = config['DROPOUT_RATE']
    OUTPUT_SIZE = config['OUTPUT_SIZE']
    T_MIN_INPUT = config['T_MIN_INPUT']
    T_MAX_INPUT = config['T_MAX_INPUT']

    out_channels_1 = CONV_CHANNELS_CONFIG[0] # e.g., 8
    out_channels_2 = CONV_CHANNELS_CONFIG[1] # e.g., 8

    # 块 1: DepthwiseSeparableConv
    ann_layers.extend([
        DepthwiseSeparableConv(
            in_channels, 
            out_channels_1, 
            kernel_size=CONV_KERNEL_SIZE_PARAM, 
            stride=2
        ),
        nn.BatchNorm2d(out_channels_1),
        nn.ReLU(inplace=True)
    ])
    
    in_channels = out_channels_1

    # 块 2: UltraLightweightGatedBlock
    ann_layers.append(
        UltraLightweightGatedBlock(
            in_channels, 
            out_channels_2, 
            kernel_size=CONV_KERNEL_SIZE_PARAM
        )
    )
    
    model.add(nn.Sequential(*ann_layers))
    
    # 动态计算 SNN 输入维度
    with torch.no_grad():
        dummy_input = torch.randn(1, 4, 8, 9)
        cnn_part = nn.Sequential(*ann_layers)
        dummy_output = cnn_part(dummy_input)
        flattened_dim = dummy_output.numel()
    
    print(f"Model created. Flattened dimension before SNN: {flattened_dim}")

    model.add(DivisionFreeAnnToSnnEncoder(t_min=T_MIN_INPUT, t_max=T_MAX_INPUT))
    model.add(nn.Flatten())
    if DROPOUT_RATE > 0:
        model.add(nn.Dropout(p=DROPOUT_RATE))
    
    model.add(SpikingDense(HIDDEN_UNITS_1, 'dense_1', input_dim=flattened_dim))
    model.add(SpikingDense(HIDDEN_UNITS_2, 'dense_2', input_dim=HIDDEN_UNITS_1))
    model.add(SpikingDense(OUTPUT_SIZE, 'dense_output', input_dim=HIDDEN_UNITS_2, outputLayer=True))
    
    return model

# --- 主执行函数 ---
def main():
    parser = argparse.ArgumentParser(description="Q1.7 Fine-tuning script for SNN model.")
    parser.add_argument('--model_path', type=str, default="1SNN_Depthwise_RandomSplit/SNN_dsc-ulgate_conv8-8_h64-32_lr5e-4_bs8_dp0_l2_0_20251109_22M49/模型_SNN_dsc-ulgate_conv8-8_h64-32_lr5e-4_bs8_dp0_l2_0_20251109_23M47.pth",help="Path to the trained FP32 .pth model file.")
    parser.add_argument('--feature_dir', type=str, default="Feature_PowerSpectrumEntropy_LDS_Smoothed_4x8x9_AllData", help="Path to the feature directory.")
    args = parser.parse_args()

    # --- 1. 微调参数 ---
    FINETUNE_LR = 5e-4      # 【修改】这现在是余弦退火的 *初始最大学习率*
    FINETUNE_EPOCHS = 100
    FINETUNE_BATCH_SIZE = 8
    
    # (model_config 和 固定参数 保持不变)
    model_config = {
        'CONV_CHANNELS': [8, 8],
        'CONV_KERNEL_SIZE': 3,
        'HIDDEN_UNITS_1': 64,
        'HIDDEN_UNITS_2': 32,
        'DROPOUT_RATE': 0,
        'OUTPUT_SIZE': 3,
        'T_MIN_INPUT': 0.0,
        'T_MAX_INPUT': 1.0,
    }
    RANDOM_SEED = 42
    TEST_SPLIT_SIZE = 0.2
    TRAINING_GAMMA = 10.0

    # (环境、设备、数据加载 保持不变)
    # --- 3. 环境与设备 ---
    torch.manual_seed(RANDOM_SEED); np.random.seed(RANDOM_SEED)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if device.type == 'cuda': torch.cuda.manual_seed_all(RANDOM_SEED)
    print(f"Using device: {device}")
    
    # --- 4. 加载数据 ---
    try:
        features_data, labels_data = load_features_from_mat(args.feature_dir)
    except FileNotFoundError as e:
        print(e); return
    
    X_train_full, X_val_full, y_train, y_val = train_test_split(
        features_data, labels_data, test_size=TEST_SPLIT_SIZE,
        random_state=RANDOM_SEED, stratify=labels_data
    )
    X_train_data = torch.tensor(X_train_full, dtype=torch.float32)
    X_val_data = torch.tensor(X_val_full, dtype=torch.float32)
    train_dataset = NumericalEEGDataset(X_train_data, y_train)
    val_dataset = NumericalEEGDataset(X_val_data, y_val)
    train_loader = DataLoader(train_dataset, batch_size=FINETUNE_BATCH_SIZE, shuffle=True, num_workers=0)
    val_loader = DataLoader(val_dataset, batch_size=FINETUNE_BATCH_SIZE, shuffle=False, num_workers=0)
    print(f"Data loaded. Using {len(train_dataset)} samples for fine-tuning, {len(val_dataset)} for validation.")

    # (模型构建和加载 保持不变)
    # --- 5. 构建模型并加载 FP32 权重 ---
    model = build_model(model_config)
    model.to(device)
    
    try:
        model.load_state_dict(torch.load(args.model_path, map_location=device))
        print(f"Successfully loaded FP32 weights from: {args.model_path}")
    except Exception as e:
        print(f"Error loading weights: {e}")
        print("Ensure the model_config parameters match the loaded model.")
        return

    criterion = nn.CrossEntropyLoss()
    
    # (初始评估 保持不变)
    # --- 6. 初始评估 (FP32) ---
    val_loss_fp32, val_acc_fp32, _, _ = evaluate_model(model, val_loader, criterion, device)
    print(f"--- Initial FP32 Model Accuracy: {val_acc_fp32:.4f} ---")

    # (初始量化 保持不变)
    # --- 7. 应用初始量化并评估 ---
    apply_weight_quantization(model)
    print("Applied initial Q1.7 quantization to weights.")
    val_loss_q_init, val_acc_q_init, _, _ = evaluate_model(model, val_loader, criterion, device)
    print(f"--- Initial Q1.7 Model Accuracy (before fine-tune): {val_acc_q_init:.4f} ---")

    # --- 8. 开始 Q1.7 微调 ---
    print(f"\nStarting Q1.7 fine-tuning for {FINETUNE_EPOCHS} epochs with initial LR={FINETUNE_LR}...")
    optimizer = optim.Adam(model.parameters(), lr=FINETUNE_LR)
    
    # --- 【修改】正确配置余弦退火 ---
    # T_max 应该是微调的总轮数 FINETUNE_EPOCHS
    # eta_min 是学习率的下限
    scheduler = CosineAnnealingLR(optimizer, T_max=FINETUNE_EPOCHS, eta_min=1e-6) 
    # --- 【修改结束】---
    
    best_finetune_val_acc = val_acc_q_init
    best_finetune_model_state_dict = copy.deepcopy(model.state_dict())

    for epoch in range(FINETUNE_EPOCHS):
        epoch_start_time = time.time()
        
        # (训练函数调用 保持不变)
        train_loss, train_acc = train_epoch_finetune(
            model, train_loader, criterion, optimizer, device, epoch,
            TRAINING_GAMMA, model_config['T_MIN_INPUT'], model_config['T_MAX_INPUT']
        )
        
        val_loss, val_acc, _, _ = evaluate_model(model, val_loader, criterion, device)
        
        # --- 【新增】获取当前LR，并在评估后更新调度器 ---
        current_lr = optimizer.param_groups[0]['lr']
        scheduler.step()
        # --- 【新增结束】---
        
        # --- 【修改】在打印信息中加入学习率 ---
        print(f"Finetune Epoch [{epoch+1}/{FINETUNE_EPOCHS}] | LR: {current_lr:.2e} | Train Loss: {train_loss:.4f}, Acc: {train_acc:.4f} | Val Loss: {val_loss:.4f}, Acc: {val_acc:.4f} | Time: {time.time() - epoch_start_time:.2f}s")
        # --- 【修改结束】---
        
        if val_acc > best_finetune_val_acc:
            best_finetune_val_acc = val_acc
            best_finetune_model_state_dict = copy.deepcopy(model.state_dict())
            print(f"  > Finetune validation accuracy improved to {best_finetune_val_acc:.4f}.")
            
    # (保存逻辑 保持不变)
    # --- 9. 加载最佳微调模型并保存 ---
    if best_finetune_model_state_dict:
        model.load_state_dict(best_finetune_model_state_dict)
    
    print(f"\n--- Q1.7 Fine-Tuning Finished ---")
    print(f"Final fine-tuned Q1.7 accuracy: {best_finetune_val_acc:.4f}")

    original_model_name = os.path.basename(args.model_path)
    save_name = original_model_name.replace(".pth", "_Q1.7_finetuned.pth")
    save_dir = os.path.dirname(args.model_path)
    save_path = os.path.join(save_dir, save_name)
    
    torch.save(model.state_dict(), save_path)
    print(f"Q1.7 fine-tuned model saved to: {save_path}")

if __name__ == "__main__":
    main()