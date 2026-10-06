unit Devbox.Focus;

{ Estado do modo foco/reunião, lido por quem precisa: o clipboard pausa, os
  avisos do Devbox esperam numa fila e o Windows pode silenciar os dele. }

interface

uses
  System.SysUtils;

var
  FocusActive: Boolean;
  FocusPauseClipboard: Boolean = True;
  FocusMuteNotify: Boolean = True;
  { Avisos que chegaram durante o foco: "título: texto". Saem juntos no fim. }
  FocusQueue: TArray<string>;

{ Liga/desliga os avisos do Windows (chave global de notificações). Devolve o
  valor anterior para restaurar depois. Experimental: o efeito pode depender
  da versão do Windows. }
function SetWindowsToasts(AEnabled: Boolean): Boolean;
function WindowsToastsEnabled: Boolean;

implementation

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Win.Registry;

const
  NotifyKey = 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings';
  NotifyValue = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED';

function WindowsToastsEnabled: Boolean;
var
  R: TRegistry;
begin
  Result := True;
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKeyReadOnly(NotifyKey) and R.ValueExists(NotifyValue) then
      Result := R.ReadInteger(NotifyValue) <> 0;
  finally
    R.Free;
  end;
end;

function SetWindowsToasts(AEnabled: Boolean): Boolean;
var
  R: TRegistry;
  Res: DWORD_PTR;
begin
  Result := WindowsToastsEnabled;
  R := TRegistry.Create;
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKey(NotifyKey, True) then
      R.WriteInteger(NotifyValue, Ord(AEnabled));
  finally
    R.Free;
  end;
  // Avisa os programas que a configuração mudou (sem esperar quem travar).
  SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, 0, LPARAM(PChar('Notifications')),
    SMTO_ABORTIFHUNG, 1000, @Res);
end;

end.
