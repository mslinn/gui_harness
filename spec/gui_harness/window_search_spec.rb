# frozen_string_literal: false

require 'spec_helper'
require 'open3'
require 'tempfile'

# The examples ask the PowerShell script about the windows of a running program.
#
# The program is put up by the examples themselves: a dialog that waits to be closed. The
# dialog belongs to a PowerShell process of its own, and the script is asked about that
# process, so that the windows it holds are the windows of that process and of no other.
RSpec.describe 'the window search of the PowerShell script' do
  # The path of the PowerShell script of the launcher.
  #
  # @return [String] the path
  def script_path
    File.expand_path '../../assets/gui_harness_live_launcher.ps1', __dir__
  end

  # Runs an expression against the PowerShell script of the launcher.
  #
  # The script is dot-sourced, so that its functions are there without the script launching
  # anything. The parameters of the script are given, because they are mandatory.
  #
  # The command is run without a shell, because a shell takes the dollar signs of the
  # expression for its own.
  #
  # @param expression [String] the PowerShell expression to run
  # @return [String] the output of the expression
  def powershell(expression)
    script = GuiHarness::LiveLauncher.windows_path script_path
    command = ". '#{script}' -Exe notepad.exe -Set C:/missing.txt; #{expression}"
    output, = Open3.capture2e 'powershell.exe', '-NoProfile', '-Command', command
    output
  end

  # Starts a PowerShell process that puts up a dialog and waits for it to be closed.
  #
  # The process writes its own pid down, so that the examples can ask the script about the
  # windows of that process.
  #
  # @param kind [Symbol] :file for a dialog that asks for a name, :message for a box that says
  #   something
  # @return [Array] the pid of the process and the pid of the process that was started
  def start_dialog(kind)
    pid_file = Tempfile.new(['gui_harness_window_search', '.pid'])
    pid_file.close
    path = GuiHarness::LiveLauncher.windows_path pid_file.path

    body = case kind
           when :file
             'Add-Type -AssemblyName PresentationFramework; ' \
             '$dialog = New-Object Microsoft.Win32.SaveFileDialog; ' \
             "$dialog.Title = 'Save Live Set As:'; " \
             "Set-Content -Path '#{path}' -Value $PID; " \
             '$null = $dialog.ShowDialog()'
           when :message
             'Add-Type -AssemblyName System.Windows.Forms; ' \
             "Set-Content -Path '#{path}' -Value $PID; " \
             '$null = [System.Windows.Forms.MessageBox]::Show(' \
             "'One or more Kontakt instances cannot be recalled correctly.')"
           end

    # The dialog is put up by a process of its own, and it goes on until it is closed. Its
    # output goes to a file, so that it does not hold the output of the examples open.
    log = Tempfile.new(['gui_harness_window_search', '.log'])
    log.close
    spawn_pid = Process.spawn 'powershell.exe', '-NoProfile', '-Command', body, out: log.path, err: log.path
    pid = wait_for_pid pid_file.path
    wait_for_window pid
    [pid, spawn_pid]
  end

  # Waits for the process to have a window of its own.
  #
  # The process writes its pid down before it puts the dialog up, so the pid is there before
  # the dialog is. The examples ask the script about the windows of the process, and the
  # answer is empty until the dialog is up.
  #
  # @param pid [Integer] the pid of the process
  def wait_for_window(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      return if powershell("@(Get-Windows #{pid}).Count").strip.to_i.positive?
      raise 'the dialog did not come up' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.2
    end
  end

  # Waits for the process to write its pid down.
  #
  # @param path [String] the path of the file the pid is in
  # @return [Integer] the pid
  def wait_for_pid(path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      break if File.exist?(path) && !File.read(path).strip.empty?
      raise 'the dialog did not come up' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.2
    end
    File.read(path).strip.to_i
  end

  # Reads the values an expression wrote down.
  #
  # The expressions write one value per line, as `name=value`. The lines that do not hold a
  # value are not values, and are left out.
  #
  # @param output [String] the output of the expression
  # @return [Hash] the values, by the name of the value
  def read_values(output)
    output.lines.map(&:chomp).select { |line| line.include?('=') }.to_h { |line| line.split('=', 2) }
  end

  # Stops a dialog that was put up.
  #
  # @param spawn_pid [Integer] the pid of the process that was started
  def stop_dialog(spawn_pid)
    Process.kill 'KILL', spawn_pid
    Process.wait spawn_pid
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # Starts Notepad, which has a window of its own.
  #
  # Notepad is used for the window of the application, because a program that puts up a dialog
  # has nothing else: the dialog is all the windows it has.
  #
  # @return [Integer] the pid of the process
  def start_notepad
    system 'powershell.exe', '-NoProfile', '-Command', 'Start-Process notepad.exe'
    pid = nil
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      output = powershell(
        '@(Get-Process -Name notepad -ErrorAction SilentlyContinue | ' \
        'Select-Object -First 1 -ExpandProperty Id)'
      ).strip
      pid = output.to_i
      break if pid.positive?
      raise 'Notepad did not start' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.2
    end
    pid
  end

  # Stops Notepad.
  def stop_notepad
    system 'powershell.exe', '-NoProfile', '-Command',
           'Stop-Process -Name notepad -Force -ErrorAction SilentlyContinue'
  end

  describe 'a dialog that asks for a name' do
    it 'is found with the field for the name and the button that confirms the save' do
      pid, spawn_pid = start_dialog :file

      expression = "$dialog = Find-FileDialog @(#{pid}); " \
                   "'class=' + $dialog.Window.Class; " \
                   "'title=' + $dialog.Window.Title; " \
                   "'edit=' + $dialog.Edit.Class; " \
                   "'save=' + $dialog.Save.Title"
      values = read_values powershell(expression)

      expect(values['class']).to eq('#32770')
      expect(values['title']).to eq('Save Live Set As:')
      expect(values['edit']).to eq('Edit')
      expect(values['save']).to match(/Save/i)
    ensure
      stop_dialog spawn_pid
    end

    it 'holds the field for the name below its own controls, and not among them' do
      pid, spawn_pid = start_dialog :file

      expression = "$dialog = Find-FileDialog @(#{pid}); " \
                   '$tree = @(Get-ChildWindows $dialog.Window.Handle); ' \
                   '$direct = @(Get-DirectChildren $dialog.Window.Handle $tree); ' \
                   '$below = @(Get-Descendants $dialog.Window.Handle $tree); ' \
                   "'tree=' + $tree.Count; " \
                   "'direct=' + $direct.Count; " \
                   "'below=' + $below.Count; " \
                   "'edit_direct=' + (@($direct | Where-Object { $_.Class -eq 'Edit' }).Count); " \
                   "'edit_below=' + (@($below | Where-Object { $_.Class -eq 'Edit' }).Count); " \
                   "'chosen_below=' + (@($below | Where-Object { $_.Handle -eq $dialog.Edit.Handle }).Count); " \
                   "'chosen_direct=' + (@($direct | Where-Object { $_.Handle -eq $dialog.Edit.Handle }).Count)"
      values = read_values powershell(expression)

      expect(values['tree'].to_i).to be > 0
      expect(values['below'].to_i).to eq(values['tree'].to_i)
      expect(values['direct'].to_i).to be < values['below'].to_i
      expect(values['edit_direct'].to_i).to eq(0)

      # The dialog holds two fields for typing: the field for the name of the file, and the
      # field for the place to look for it. The field for the name is the one that is chosen.
      expect(values['edit_below'].to_i).to eq(2)
      expect(values['chosen_below'].to_i).to eq(1)
      expect(values['chosen_direct'].to_i).to eq(0)
    ensure
      stop_dialog spawn_pid
    end

    it 'is not taken for a box that says something' do
      pid, spawn_pid = start_dialog :file

      expect(powershell("@(Find-MessageDialogs @(#{pid})).Count").strip.to_i).to eq(0)
    ensure
      stop_dialog spawn_pid
    end
  end

  describe 'a box that says something' do
    it 'is found with its text and the button that answers it' do
      pid, spawn_pid = start_dialog :message

      expression = "$dialogs = @(Find-MessageDialogs @(#{pid})); " \
                   "'count=' + $dialogs.Count; " \
                   "'text=' + $dialogs[0].Text; " \
                   "'button=' + $dialogs[0].Buttons[0].Title"
      values = read_values powershell(expression)

      expect(values['count'].to_i).to eq(1)
      expect(values['text']).to include('Kontakt instances cannot be recalled')
      expect(values['button']).to eq('OK')
    ensure
      stop_dialog spawn_pid
    end

    it 'is dismissed by pressing the button that answers it' do
      pid, spawn_pid = start_dialog :message

      expression = "$dialog = @(Find-MessageDialogs @(#{pid}))[0]; " \
                   "'pressed=' + (Press-Button $dialog.Buttons[0])"
      values = read_values powershell(expression)

      expect(values['pressed']).to eq('True')
    ensure
      stop_dialog spawn_pid
    end
  end

  describe 'the window of the application' do
    it 'is the window of the program, and not a dialog' do
      pid = start_notepad

      expression = "$window = Find-MainWindow #{pid}; " \
                   "'class=' + $window.Class; " \
                   "'title=' + $window.Title"
      values = read_values powershell(expression)

      expect(values['class']).not_to eq('#32770')
      expect(values['class']).not_to be_empty
      expect(values['title']).not_to be_empty
    ensure
      stop_notepad
    end

    it 'is nothing at all when the program has only a dialog' do
      pid, spawn_pid = start_dialog :message

      expect(powershell("Find-MainWindow #{pid}").strip).to be_empty
    ensure
      stop_dialog spawn_pid
    end
  end
end
