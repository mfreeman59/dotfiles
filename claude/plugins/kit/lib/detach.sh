# 完全に切り離したプロセスの起動（設計書 §7.1）。
# SessionEnd フックの持ち時間は 1.5 秒しかなく、Claude Code の終了とともにフックのプロセスグループが
# 終了させられる可能性がある。そこで fork してから setsid し、Claude Code のセッションとプロセスグループの
# 両方から外れた子で処理を続ける。macOS には setsid コマンドがないので perl を使う。

# kit_detach <cmd...>: 呼び出し元はすぐ戻る。子の出力は sync.log に追記する
kit_detach() {
  kit_init_state
  KIT_DETACH_LOG="${KIT_STATE}/sync.log" perl -MPOSIX -e '
    my $pid = fork;
    exit 1 unless defined $pid;
    exit 0 if $pid;
    POSIX::setsid();
    open STDIN, "<", "/dev/null";
    open STDOUT, ">>", $ENV{KIT_DETACH_LOG};
    open STDERR, ">&", \*STDOUT;
    exec @ARGV or exit 127;
  ' -- "$@"
}
