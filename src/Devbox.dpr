program Devbox;

uses
  Winapi.Windows,
  System.SysUtils,
  Vcl.Forms,
  UI.Runtime.Vcl,
  Devbox.Model in 'Devbox.Model.pas',
  Devbox.Store in 'Devbox.Store.pas',
  Devbox.Sys in 'Devbox.Sys.pas',
  Devbox.UI.Main in 'Devbox.UI.Main.pas';

var
  Mutex: THandle;

begin
  Mutex := CreateMutex(nil, True, PChar('Local\Devbox.' +
    StringReplace(GetEnvironmentVariable('USERDOMAIN') + '.' + GetEnvironmentVariable('USERNAME'),
      '\', '.', [rfReplaceAll])));
  if GetLastError = ERROR_ALREADY_EXISTS then
  begin
    PostMessage(FindWindow('TMainForm', PChar('Devbox ' + AppVersion)),
      RegisterWindowMessage(ShowMessageName), 0, 0);
    Exit;
  end;
  try
    Application.Initialize;
    Application.ShowMainForm := False;
    Application.Title := 'Devbox';
    Application.CreateForm(TMainForm, MainForm);
    if FindCmdLineSwitch('show') then
      MainForm.Show;
    Application.Run;
  finally
    CloseHandle(Mutex);
  end;
end.
