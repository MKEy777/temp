#include "clientwindow.h" // 包含我们修改后的主窗口头文件
#include <QApplication>
#include <QInputDialog>   // 用于创建输入对话框
#include <QString>

int main(int argc, char *argv[])
{
    QApplication a(argc, argv);

    bool ok_ip;
    // 弹窗让用户输入服务器IP，默认值为我们服务器的地址
    QString server_ip = QInputDialog::getText(0, "连接到服务器",
                                              "请输入服务器IP地址:", QLineEdit::Normal,
                                              "192.168.6.129", &ok_ip);

    // 如果用户点击了取消或者没有输入，则退出程序
    if (!ok_ip || server_ip.isEmpty()) {
        return 0;
    }

    bool ok_user;
    // 弹窗让用户输入昵称
    QString username = QInputDialog::getText(0, "输入昵称",
                                             "输入你的昵称:", QLineEdit::Normal,
                                             "", &ok_user);

    // 如果用户点击了取消或者没有输入，则退出程序
    if (!ok_user || username.isEmpty()) {
        return 0;
    }

    // 只有当IP和昵称都成功获取后，才创建并显示主聊天窗口
    ClientWindow w(username, server_ip);
    w.show();

    return a.exec();
}
