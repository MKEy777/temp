#ifndef CLIENTWINDOW_H
#define CLIENTWINDOW_H

#include <QWidget>
#include "networkmanager.h" // 包含我们的网络核心类
#include <QStringList>

// 向前声明UI类
namespace Ui {
class ClientWindow;
}

class ClientWindow : public QWidget
{
    Q_OBJECT

public:
    // 构造函数接收登录时输入的用户名和服务器IP
    explicit ClientWindow(const QString& username, const QString& server_ip, QWidget *parent = 0);
    ~ClientWindow();

private slots:
    // --- UI控件的槽函数 ---
    void on_sendButton_clicked();
    void on_messageLineEdit_returnPressed();

    // --- 响应NetworkManager信号的槽函数 ---
    void handle_connected();
    void handle_disconnected();
    void handle_chat_message(const QString& username, const QString& text);
    void handle_user_list(const QStringList& users);
    void handle_system_notification(const QString& message);
    void handle_connection_error(const QString& error_message);

private:
    // 辅助函数，用于向聊天记录框追加消息
    void append_message(const QString& message);

    Ui::ClientWindow *ui; // 指向UI界面的指针
    NetworkManager* network_manager_; // 指向网络核心的指针
    QString username_; // 保存当前用户的昵称
};

#endif // CLIENTWINDOW_H
