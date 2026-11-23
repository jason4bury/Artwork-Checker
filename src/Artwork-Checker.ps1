<#
.SYNOPSIS
    Artwork Checker - Finds films, shows and albums with missing or low-quality posters and cover art.

.DESCRIPTION
    PowerShell/WPF tool for finding missing or low-quality posters and cover art.

    Project layout (house style):
        <project>\Source\               the git repo (this script is in Source\src\)
        <project>\Source\assets\        icon (.ico) and logo (.png)
        <project>\Builds\               "Artwork Checker v<version>\" release folders, their zips and
                                        "Artwork Checker.lnk", made by Build.cmd (no exe)
    Settings and data: %APPDATA%\Artwork Checker

.NOTES
    Author:    Jason Rhodes
    Copyright: (c) 2026 Jason Rhodes - MIT licence (see LICENSE)
    Version:   see $script:AppVersion below and CHANGELOG.md
    Runs in Windows PowerShell 5.1 on an STA thread (WPF needs it).
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# The version lives here and in CHANGELOG.md; Build.cmd stops if they disagree.
# Two-digit minor: 1.00, 1.01 ... 1.10. The release folder is "Artwork Checker v<version>".
$script:AppName     = 'Artwork Checker'
$script:AppVersion  = '1.03'
$script:Description = 'PowerShell/WPF tool for finding missing or low-quality posters and cover art'
$script:Copyright   = 'Copyright (c) 2026 Jason Rhodes'
$script:RepoUrl     = 'https://github.com/jason4bury/Artwork-Checker'
$script:IsPrivate   = $false  # public tool: settings and data in %APPDATA%\<App Name>
$script:AppId       = 'jason4bury.Artwork-Checker'   # taskbar ID; the shortcut made by New-ArtworkCheckerShortcut.ps1 uses the same one

# ---------------------------------------------------------------------------
#  Where is everything? No exe: this script runs from Source\src\ (while
#  developing) or from a release folder, Builds\Artwork Checker v<version>\ (or
#  wherever the release zip was unpacked), with assets\ beside it.
# ---------------------------------------------------------------------------
# WPF needs an STA thread. Started any other way, restart in Windows PowerShell with -STA.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    return
}

# One taskbar button with the tool's own icon (not PowerShell's), and pinning it pins the tool.
try {
    Add-Type -Namespace 'HomeTool' -Name 'Shell' -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);'
    [void][HomeTool.Shell]::SetCurrentProcessExplicitAppUserModelID($script:AppId)
} catch { Write-Verbose "No taskbar ID: $($_.Exception.Message)" }

$script:ProgramDir = Split-Path -Parent $PSCommandPath
$script:AssetsDir  = @((Join-Path $script:ProgramDir 'assets'), (Join-Path (Split-Path -Parent $script:ProgramDir) 'assets')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $script:AssetsDir) { $script:AssetsDir = Join-Path $script:ProgramDir 'assets' }

function Get-DataDir {
    <# Public tools: %APPDATA%\<App Name>. Private tools: <project>\Data, beside Source\ and
       Builds\, so nothing is written to the unencrypted drive. Never inside Source\ (keeps
       personal data out of git) or a release folder (each version has its own, so data kept
       there would be left behind by the next version). #>
    if (-not $script:IsPrivate) { return (Join-Path $env:APPDATA $script:AppName) }
    $up = Split-Path -Parent $script:ProgramDir
    # Source\src\<script> or Builds\<App> v<x.yy>\<script>: <project> is two levels up.
    if (@('Source', 'Builds') -contains (Split-Path -Leaf $up)) { return (Join-Path (Split-Path -Parent $up) 'Data') }
    return (Join-Path $script:ProgramDir 'Data')   # an unpacked release zip somewhere else
}
$script:DataDir      = Get-DataDir
$script:SettingsPath = Join-Path $script:DataDir 'settings.json'
$script:LogPath      = Join-Path $script:DataDir "$($script:AppName).log"
if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# ---------------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------------
function Write-AppLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $script:LogPath -Value ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 }
    catch { Write-Verbose "Couldn't write the log: $($_.Exception.Message)" }
}

function Get-AssetImage {
    <# A frozen BitmapImage for a WPF Image or window Icon, or $null if the asset is missing. #>
    param([string]$Name)
    $path = Join-Path $script:AssetsDir $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $img = New-Object Windows.Media.Imaging.BitmapImage
    $img.BeginInit()
    $img.StreamSource = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path))
    $img.CacheOption  = 'OnLoad'
    $img.EndInit(); $img.Freeze()
    return $img
}


function Get-AppSetting {
    <# Settings from settings.json in the data folder: the look, the music folders, the smallest
       sizes, the media server and the last tab. #>
    # To begin with: nothing (no music folders, no server address); everything is set in Sources...
    $s = @{ Look = 'Light'; MusicFrom = 'PC'; PcRoots = @(); NasRoots = @(); MusicPictures = ''; FilmPictures = ''
            CheckArtists = $true; CoverSize = 500; MinPoster = 600; Tab = 'Music'
            AlbumFolder = 'Album Pictures'; ArtistFolder = 'Artist Pics'; FilmFolder = 'Movies'; TvFolder = 'TV'
            ServerKind = 'Jellyfin'; JellyfinUrl = ''; JellyfinKey = ''; PlexUrl = ''; PlexKey = ''; EmbyUrl = ''; EmbyKey = '' }
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $j = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                switch ($p.Name) {
                    { $_ -in 'PcRoots', 'NasRoots' } { $s[$p.Name] = @($p.Value | ForEach-Object { [string]$_ }) }
                    'CheckArtists' { $s.CheckArtists = [bool]$p.Value }
                    { $_ -in 'CoverSize', 'MinPoster' } { if ("$($p.Value)" -match '^\d+$') { $s[$p.Name] = [int]$p.Value } }
                    { $_ -in 'AlbumFolder', 'ArtistFolder', 'FilmFolder', 'TvFolder' } { if ("$($p.Value)".Trim()) { $s[$p.Name] = "$($p.Value)".Trim() } }
                    default        { $s[$p.Name] = [string]$p.Value }
                }
            }
        } catch { Write-AppLog "settings.json couldn't be read: $($_.Exception.Message)" }
    }
    return $s
}

function Get-MusicRoots {
    <# The music folders in use: this PC's or the NAS's, as chosen in Sources... #>
    if ($script:Settings.MusicFrom -eq 'NAS') { return @($script:Settings.NasRoots | Where-Object { $_ }) }
    return @($script:Settings.PcRoots | Where-Object { $_ })
}

function Save-AppSetting {
    try { [pscustomobject]$script:Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8 }
    catch { Write-AppLog "settings.json couldn't be saved: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  Look: Light, Dark or System (follow Windows). Used from the next start.
# ---------------------------------------------------------------------------
$script:Settings = Get-AppSetting
function Test-DarkLook {
    switch ($script:Settings.Look) {
        'Dark' { return $true }
        'System' {
            try { return ([int](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) }
            catch { return $false }
        }
        default { return $false }
    }
}
$script:Dark = Test-DarkLook
$script:Palette = if ($script:Dark) {
    @{ Page = '#16191E'; Card = '#1F242B'; Line = '#343B45'; Ink = '#E6E9EE'; Soft = '#9AA3AE'; Accent = '#4C9BE8'; AccentInk = '#FFFFFF'
       Field = '#14171B'; UpdateBack = '#3A3022'; Hover = '#2A313A'; Select = '#24425F'; Good = '#4CC38A'; Warn = '#E0A040'; Bad = '#F07178'; Changed = '#2B3A2E' }
} else {
    @{ Page = '#F3F5F8'; Card = '#FFFFFF'; Line = '#D7DCE3'; Ink = '#1E2530'; Soft = '#5E6875'; Accent = '#1F6FBF'; AccentInk = '#FFFFFF'
       Field = '#FFFFFF'; UpdateBack = '#FFF4E0'; Hover = '#EAF0F7'; Select = '#D6E6F7'; Good = '#1E8A57'; Warn = '#9A5B00'; Bad = '#B3261E'; Changed = '#E7F5EC' }
}
$script:BrushConv = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$Key) { return $script:BrushConv.ConvertFromString($script:Palette[$Key]) }

function Set-TitleBar([Windows.Window]$Window) {
    <# A dark title bar in the dark look (Windows 10 20H1 and later; older Windows ignores it). #>
    if (-not $script:Dark) { return }
    try {
        if (-not ('AcDwm' -as [type])) { Add-Type -Namespace '' -Name 'AcDwm' -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);' }
        $h = (New-Object Windows.Interop.WindowInteropHelper $Window).EnsureHandle()
        $on = 1; [void][AcDwm]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)
    } catch { Write-Verbose 'no dark title bar' }
}

function Expand-Xaml([string]$Xaml) {
    <# Puts the look's colours into a window's XAML ({Page}, {Ink} ...). #>
    foreach ($k in $script:Palette.Keys) { $Xaml = $Xaml.Replace("{$k}", $script:Palette[$k]) }
    return $Xaml
}

function New-XamlWindow {
    param([Parameter(Mandatory)][string]$Xaml, [Windows.Window]$Owner)
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Expand-Xaml $Xaml))))
    if ($Owner) { $w.Owner = $Owner; $w.Icon = $Owner.Icon }
    $w.Add_SourceInitialized({ Set-TitleBar $this })
    return $w
}

# Shared styles: rounded buttons (normal and accent), text boxes and the list.
$script:Styles = @'
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Background" Value="{Card}"/><Setter Property="BorderBrush" Value="{Line}"/>
      <Setter Property="Padding" Value="14,6"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="B" Property="Background" Value="{Select}"/><Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/>
            <Setter TargetName="B" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></Setter.Value></Setter>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{Accent}"/><Setter Property="Foreground" Value="{AccentInk}"/><Setter Property="BorderBrush" Value="{Accent}"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderThickness="0" CornerRadius="6" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.88"/></Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="B" Property="Opacity" Value="0.7"/>
            <Setter TargetName="B" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></Setter.Value></Setter>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <!-- Slim rounded scroll bars: a thin handle on a clear track, no arrow buttons. It widens a
         little while the pointer is over it and darkens on hover and drag. -->
    <Style x:Key="BuThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border x:Name="T" CornerRadius="4" Background="{Line}"/>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="{Soft}"/></Trigger>
          <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Background" Value="{Accent}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="BuPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Vertical">
          <Setter Property="Width" Value="12"/><Setter Property="MinWidth" Value="12"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True" Width="6" HorizontalAlignment="Center" Margin="0,3">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource BuThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PART_Track" Property="Width" Value="9"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Height" Value="12"/><Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" Height="6" VerticalAlignment="Center" Margin="3,0">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource BuThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PART_Track" Property="Height" Value="9"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{Field}"/><Setter Property="Foreground" Value="{Ink}"/><Setter Property="BorderBrush" Value="{Line}"/>
      <Setter Property="CaretBrush" Value="{Ink}"/><Setter Property="Padding" Value="6,4"/><Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
'@

#region MESSAGES
# ---------------------------------------------------------------------------
#  Messages and questions in the app's own look (not Windows' grey MessageBox)
# ---------------------------------------------------------------------------
$script:MessageXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="Height" Width="460" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22,18,22,16">
    <TextBlock x:Name="MsgText" TextWrapping="Wrap" LineHeight="20"/>
    <TextBox x:Name="MsgInput" Margin="0,12,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="MsgYes" Style="{StaticResource Accent}" MinWidth="80" IsDefault="True"/>
      <Button x:Name="MsgNo" MinWidth="80" Margin="0" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Show-AppMessage {
    <# A message, a question (with -NoText: $true for the first button) or, with -Ask,
       a question with a text box (returns the text, or $null when cancelled). #>
    param([Parameter(Mandatory)][string]$Text, [string]$Title = $script:AppName, [string]$YesText = 'OK', [string]$NoText,
          [switch]$Ask, [string]$Default = '', [Windows.Window]$Owner = $script:Window)
    $w = New-XamlWindow $script:MessageXaml $Owner
    $w.Title = $Title
    $w.FindName('MsgText').Text = $Text
    $yes = $w.FindName('MsgYes'); $no = $w.FindName('MsgNo'); $box = $w.FindName('MsgInput')
    $yes.Content = $YesText
    if ($NoText) { $no.Content = $NoText } else { $no.Visibility = 'Collapsed'; $yes.Margin = '0'; $yes.IsCancel = $true }
    if ($Ask) { $box.Visibility = 'Visible'; $box.Text = $Default; $w.Add_ContentRendered({ $box.Focus(); $box.SelectAll() }) }
    $script:MsgAnswer = $false
    $yes.Add_Click({ $script:MsgAnswer = $true; $w.Close() })
    $no.Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
    if ($Ask) { if ($script:MsgAnswer) { return $box.Text.Trim() } else { return $null } }
    return $script:MsgAnswer
}
#endregion MESSAGES

#region ABOUT-BOX
# ---------------------------------------------------------------------------
#  About box (house style): logo, name, version, the one-line description,
#  the copyright and MIT licence, the repo link and where settings live.
# ---------------------------------------------------------------------------
$script:AboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22" MaxWidth="440">
    <StackPanel Orientation="Horizontal">
      <Image x:Name="AboutLogo" Width="64" Height="64" Margin="0,0,16,0" RenderOptions.BitmapScalingMode="HighQuality"/>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="AboutName" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock x:Name="AboutVersion" Foreground="{Soft}"/>
      </StackPanel>
    </StackPanel>
    <TextBlock x:Name="AboutDescription" TextWrapping="Wrap" Margin="0,14,0,0"/>
    <TextBlock x:Name="AboutData" TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{Soft}"/>
    <TextBlock Margin="0,10,0,0"><Hyperlink x:Name="AboutRepo" Foreground="{Accent}"><Run x:Name="AboutRepoText"/></Hyperlink></TextBlock>
    <TextBlock x:Name="AboutCopyright" Margin="0,4,0,0" Foreground="{Soft}"/>
    <Button x:Name="AboutClose" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,16,0,0" IsDefault="True" IsCancel="True"/>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Show-About {
    param([Windows.Window]$Owner)
    $w = New-XamlWindow $script:AboutXaml $Owner
    $w.Title = "About $script:AppName"
    $w.FindName('AboutLogo').Source       = Get-AssetImage 'Artwork-Checker.png'
    $w.FindName('AboutName').Text         = $script:AppName
    $w.FindName('AboutVersion').Text      = "Version $script:AppVersion"
    $w.FindName('AboutDescription').Text  = $script:Description
    $w.FindName('AboutData').Text         = "Settings and data: $script:DataDir"
    $w.FindName('AboutRepoText').Text     = $script:RepoUrl
    $w.FindName('AboutRepo').NavigateUri  = [Uri]$script:RepoUrl
    $w.FindName('AboutRepo').Add_RequestNavigate({ param($s, $e) Start-Process $e.Uri.AbsoluteUri; $e.Handled = $true })
    $w.FindName('AboutCopyright').Text    = "$script:Copyright  ·  MIT licence"
    $w.FindName('AboutClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}
#endregion ABOUT-BOX

#region CHECKS
# ---------------------------------------------------------------------------
#  Reading images and tags. Only the first few bytes of each file are read:
#  the size of a picture is in its header, so a scan over the network stays quick.
# ---------------------------------------------------------------------------
if (-not ('AcItem' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;

// One line in the list: an album, artist, film, show or season, and what is wrong with its picture.
public class AcItem {
    public string Kind { get; set; }      // Album, Artist, Film, Show, Season
    public string Tab { get; set; }       // Music, Films, TV
    public string Name { get; set; }
    public string Group { get; set; }     // the artist (albums) or the show (seasons)
    public string Problem { get; set; }
    public int Severity { get; set; }     // 0 fine, 1 worth a look, 2 missing or poor
    public string Image { get; set; }     // file path, or the server's image address
    public int Width { get; set; }
    public int Height { get; set; }
    public string Size { get; set; }
    public string Where { get; set; }     // the folder, or the server's path
    public string ItemId { get; set; }    // the server's id (films and TV)
    public string Copy { get; set; }      // where the poster's saved copy goes (films and TV)
    public bool CanSave { get; set; }     // the server has a poster and the copy isn't saved yet
    public string Page { get; set; }      // the item's page in the server (films and TV)
    public string Backdrop { get; set; }  // the server's background picture, if it has one
    public int SevOther { get; set; }     // the severity once the copy is saved
}

public static class AcImage {
    static int Be16(byte[] b, int i) { return (b[i] << 8) | b[i + 1]; }
    static int Le16(byte[] b, int i) { return b[i] | (b[i + 1] << 8); }
    static int Be32(byte[] b, int i) { return (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]; }
    static int Le24(byte[] b, int i) { return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16); }

    static int ReadFully(Stream s, byte[] buf, int count) {
        int got = 0;
        while (got < count) { int n = s.Read(buf, got, count - got); if (n <= 0) break; got += n; }
        return got;
    }

    // Width and height of a JPEG, PNG, GIF, BMP or WebP picture, or null if it can't be read.
    public static int[] Size(string path) {
        using (var s = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096)) {
            var h = new byte[32];
            int n = ReadFully(s, h, 32);
            if (n < 10) return null;
            if (h[0] == 0x89 && h[1] == 0x50 && n >= 24) return new[] { Be32(h, 16), Be32(h, 20) };          // PNG
            if (h[0] == 'G' && h[1] == 'I' && h[2] == 'F') return new[] { Le16(h, 6), Le16(h, 8) };          // GIF
            if (h[0] == 'B' && h[1] == 'M' && n >= 26) return new[] { BitConverter.ToInt32(h, 18), Math.Abs(BitConverter.ToInt32(h, 22)) };
            if (h[0] == 'R' && h[8] == 'W' && h[9] == 'E' && n >= 30) {                                         // WebP
                string kind = Encoding.ASCII.GetString(h, 12, 4);
                if (kind == "VP8 ") return new[] { Le16(h, 26) & 0x3FFF, Le16(h, 28) & 0x3FFF };
                if (kind == "VP8L") { int b0 = h[21], b1 = h[22], b2 = h[23], b3 = h[24];
                    return new[] { 1 + (((b1 & 0x3F) << 8) | b0), 1 + (((b3 & 0xF) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6)) }; }
                if (kind == "VP8X") return new[] { 1 + Le24(h, 24), 1 + Le24(h, 27) };
                return null;
            }
            if (h[0] == 0xFF && h[1] == 0xD8) {                                                                 // JPEG: walk the markers
                long pos = 2; var m = new byte[9];
                for (int guard = 0; guard < 400; guard++) {
                    s.Position = pos;
                    if (ReadFully(s, m, 9) < 9) return null;
                    if (m[0] != 0xFF) return null;
                    int marker = m[1];
                    if (marker == 0xFF) { pos++; continue; }
                    if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC)
                        return new[] { Be16(m, 7), Be16(m, 5) };
                    if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) { pos += 2; continue; }
                    pos += 2 + Be16(m, 2);
                }
            }
        }
        return null;
    }

    // Size of a picture held in memory (from the media server).
    public static int[] SizeOf(byte[] b) {
        string tmp = Path.GetTempFileName();
        try { File.WriteAllBytes(tmp, b); return Size(tmp); } finally { try { File.Delete(tmp); } catch { } }
    }

    // True when a music file carries its own cover picture (MP3 ID3 APIC, FLAC PICTURE, M4A covr).
    public static bool HasEmbeddedArt(string path) {
        string ext = Path.GetExtension(path).ToLowerInvariant();
        using (var s = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 8192)) {
            var h = new byte[10];
            if (ReadFully(s, h, 10) < 10) return false;
            if (h[0] == 'I' && h[1] == 'D' && h[2] == '3') {
                int size = (h[6] << 21) | (h[7] << 14) | (h[8] << 7) | h[9];
                size = Math.Min(size, 32 * 1024 * 1024);
                var tag = new byte[size];
                int got = ReadFully(s, tag, size);
                string id = h[3] == 2 ? "PIC" : "APIC";
                return IndexOf(tag, got, Encoding.ASCII.GetBytes(id)) >= 0;
            }
            if (h[0] == 'f' && h[1] == 'L' && h[2] == 'a' && h[3] == 'C') {
                long pos = 4; var bh = new byte[4];
                for (int guard = 0; guard < 128; guard++) {
                    s.Position = pos;
                    if (ReadFully(s, bh, 4) < 4) return false;
                    int type = bh[0] & 0x7F; bool last = (bh[0] & 0x80) != 0;
                    if (type == 6) return true;
                    if (last) return false;
                    pos += 4 + ((bh[1] << 16) | (bh[2] << 8) | bh[3]);
                }
                return false;
            }
            if (ext == ".m4a" || ext == ".mp4" || ext == ".m4b" || ext == ".alac") {
                // The cover sits in the 'covr' atom, at the start or the end of the file.
                var covr = Encoding.ASCII.GetBytes("covr");
                int chunk = (int)Math.Min(s.Length, 4 * 1024 * 1024);
                var buf = new byte[chunk];
                s.Position = 0; int got = ReadFully(s, buf, chunk);
                if (IndexOf(buf, got, covr) >= 0) return true;
                if (s.Length > chunk) { s.Position = s.Length - chunk; got = ReadFully(s, buf, chunk); return IndexOf(buf, got, covr) >= 0; }
            }
        }
        return false;
    }

    static int IndexOf(byte[] hay, int len, byte[] needle) {
        for (int i = 0; i + needle.Length <= len; i++) {
            int j = 0;
            while (j < needle.Length && hay[i + j] == needle[j]) j++;
            if (j == needle.Length) return i;
        }
        return -1;
    }
}
'@
}

# The scans run in a background runspace, so the window stays usable. They share $Sync with the
# window: new lines go into Sync.Items, and Sync.Done / Sync.Now / Sync.Finished show the progress.
$script:MusicScan = {
    param($Sync, [string[]]$Roots, [string]$Graphics, [int]$CoverSize, [bool]$Artists, [string]$AlbumSub = 'Album Pictures', [string]$ArtistSub = 'Artist Pics')
    # Each album folder (a folder with music files) should have cover.jpg, and a copy in
    # <Graphics>\<AlbumSub>\<Artist>\<Artist> - <Album>.jpg, both exactly CoverSize x CoverSize.
    # Each artist should have <Graphics>\<ArtistSub>\<Artist>\folder.jpg and artist.jpg in its folder
    # (any size). The two folder names are set in Sources...
    $audio = @('.mp3', '.flac', '.m4a', '.ogg', '.opus', '.wma', '.wav', '.aac', '.ape', '.wv', '.aiff', '.aif', '.dsf', '.alac')
    $pics  = @('.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp')
    $coverNames  = @('cover', 'folder', 'front', 'album', 'albumart')
    $albumPics  = if ($Graphics) { Join-Path $Graphics $AlbumSub } else { '' }
    $artistPics = if ($Graphics) { Join-Path $Graphics $ArtistSub } else { '' }

    function Add-Line($Kind, $Name, $Group, [string[]]$Problems, $Severity, $Image, $Size, $Where) {
        $i = New-Object AcItem
        $i.Kind = $Kind; $i.Tab = 'Music'; $i.Name = $Name; $i.Group = $Group; $i.Severity = $Severity
        $i.Problem = if ($Problems.Count) { $Problems -join '; ' } else { 'OK' }
        $i.Image = $Image; $i.Where = $Where
        if ($Size) { $i.Width = $Size[0]; $i.Height = $Size[1]; $i.Size = '{0} x {1}' -f $Size[0], $Size[1] }
        [void]$Sync.Items.Add($i)
    }

    function Find-Picture([string]$Dir, [string[]]$Names) {
        # The first picture named cover.jpg, folder.png ... (in that order), else any picture.
        if (-not [IO.Directory]::Exists($Dir)) { return $null }
        $files = @([IO.Directory]::EnumerateFiles($Dir) | Where-Object { $pics -contains [IO.Path]::GetExtension($_).ToLowerInvariant() })
        foreach ($n in $Names) {
            $hit = $files | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_) -ieq $n } | Select-Object -First 1
            if ($hit) { return @{ Path = $hit; Named = $true } }
        }
        if ($files.Count) { return @{ Path = $files[0]; Named = $false } }
        return $null
    }

    function Find-File([string]$Base) {
        # <Base>.jpg, .jpeg or .png, whichever is there.
        foreach ($e in '.jpg', '.jpeg', '.png') { if ([IO.File]::Exists("$Base$e")) { return "$Base$e" } }
        return $null
    }

    function Get-Size([string]$Path) { try { return [AcImage]::Size($Path) } catch { return $null } }

    try {
        $rootSet = @($Roots | ForEach-Object { $_.TrimEnd('\') })
        if ($Graphics -and -not (Test-Path -LiteralPath $Graphics)) { $Sync.Errors += "Not found: $Graphics" }
        $albums = @{}; $artistDirs = @{}; $rootOf = @{}
        foreach ($r in $Roots) { if ([IO.Directory]::Exists($r)) { foreach ($d in [IO.Directory]::GetDirectories($r)) { $rootOf[$d] = $r } } }
        $stack = New-Object Collections.Stack
        foreach ($r in @($Roots | Sort-Object -Descending)) { if (Test-Path -LiteralPath $r) { $stack.Push($r) } else { $Sync.Errors += "Not found: $r" } }
        while ($stack.Count -and -not $Sync.Cancel) {
            $dir = $stack.Pop()
            $Sync.Now = $dir
            try {
                $subs = @([IO.Directory]::GetDirectories($dir) | Where-Object { [IO.Path]::GetFileName($_) -notmatch '^[.$@#]' } | Sort-Object -Descending)
                foreach ($d in $subs) { $stack.Push($d) }
                $hasAudio = $false
                foreach ($f in [IO.Directory]::EnumerateFiles($dir)) { if ($audio -contains [IO.Path]::GetExtension($f).ToLowerInvariant()) { $hasAudio = $f; break } }
            } catch { $Sync.Errors += "$($dir): $($_.Exception.Message)"; continue }
            $Sync.Done++
            if (-not $hasAudio) { continue }
            # "CD1", "Disc 2": the album is the folder above.
            $albumDir = $dir
            if ([IO.Path]::GetFileName($dir) -match '^(cd|disc|disk)\s*\d+$') { $albumDir = [IO.Path]::GetDirectoryName($dir) }
            if ($albums.ContainsKey($albumDir)) { continue }
            $albums[$albumDir] = $true
            $parent = [IO.Path]::GetDirectoryName($albumDir)
            $artist = if ($rootSet -contains $parent.TrimEnd('\')) { '' } else { [IO.Path]::GetFileName($parent) }
            if ($artist) { $artistDirs[$parent] = $true }
            $name = [IO.Path]::GetFileName($albumDir)
            $problems = New-Object Collections.Generic.List[string]; $sev = 0; $show = $null; $showSize = $null

            # 1. The copy in <Graphics>\<AlbumSub>, else in <Graphics>\<music folder's name>
            #    (such as Compilations). The name may end with the year: "<Artist> - <Album> (1987).jpg".
            if ($albumPics -and $artist) {
                $root = $rootOf[$parent]
                $picDirs = @($albumPics)
                if ($root) { $own = Join-Path $Graphics ([IO.Path]::GetFileName($root.TrimEnd(''))); if ([IO.Directory]::Exists($own)) { $picDirs += $own } }
                $copy = $null; $picName = $AlbumSub
                foreach ($pd in $picDirs) {
                    $ad = Join-Path $pd $artist
                    $copy = Find-File (Join-Path $ad "$artist - $name")
                    if (-not $copy -and [IO.Directory]::Exists($ad)) {
                        $copy = @([IO.Directory]::GetFiles($ad, "$artist - $name (*).*") | Where-Object { $pics -contains [IO.Path]::GetExtension($_).ToLowerInvariant() }) | Select-Object -First 1
                    }
                    if ($copy) { $picName = [IO.Path]::GetFileName($pd); break }
                }
                if (-not $copy) { $problems.Add("Not in $AlbumSub"); $sev = 2 }
                else {
                    $size = Get-Size $copy
                    $show = $copy; $showSize = $size
                    if (-not $size) { $problems.Add("Can't read the $picName copy"); $sev = 2 }
                    elseif ($size[0] -ne $CoverSize -or $size[1] -ne $CoverSize) { $problems.Add("$picName copy is $($size[0]) x $($size[1])"); $sev = 2 }
                }
            }
            # 2. cover.jpg in the album folder
            $pic = Find-Picture $albumDir $coverNames
            if (-not $pic -and $dir -ne $albumDir) { $pic = Find-Picture $dir $coverNames }
            if ($pic) {
                $size = Get-Size $pic.Path
                if (-not $show) { $show = $pic.Path; $showSize = $size }
                if (-not $size) { $problems.Add("Can't read cover.jpg"); $sev = 2 }
                elseif ($size[0] -ne $CoverSize -or $size[1] -ne $CoverSize) { $problems.Add("cover.jpg is $($size[0]) x $($size[1])"); $sev = 2 }
                elseif (-not $pic.Named) { $problems.Add("Cover isn't named cover.jpg"); $sev = [Math]::Max($sev, 1) }
            } else {
                $embedded = $false
                try { $embedded = [AcImage]::HasEmbeddedArt($hasAudio) } catch { $embedded = $false }
                if ($embedded) { $problems.Add('No cover.jpg (the tracks carry their own)'); $sev = [Math]::Max($sev, 1) }
                else { $problems.Add('No cover.jpg'); $sev = 2 }
            }
            Add-Line 'Album' $name $artist $problems.ToArray() $sev $show $showSize $albumDir
        }
        if ($Artists -and -not $Sync.Cancel) {
            foreach ($a in ($artistDirs.Keys | Sort-Object)) {
                if ($Sync.Cancel) { break }
                $Sync.Now = $a
                $name = [IO.Path]::GetFileName($a)
                $problems = New-Object Collections.Generic.List[string]; $sev = 0; $show = $null
                if ($artistPics) {
                    $copy = Find-File (Join-Path (Join-Path $artistPics $name) 'folder')
                    if ($copy) { $show = $copy } else { $problems.Add("Not in $ArtistSub"); $sev = 2 }
                }
                $own = Find-File (Join-Path $a 'artist')
                if ($own) { if (-not $show) { $show = $own } } else { $problems.Add('No artist.jpg in its folder'); $sev = [Math]::Max($sev, 1) }
                $size = if ($show) { Get-Size $show } else { $null }
                Add-Line 'Artist' $name '' $problems.ToArray() $sev $show $size $a
            }
        }
    } catch {
        $Sync.Errors += $_.Exception.Message
    } finally {
        $Sync.Finished = $true
    }
}

$script:ServerScan = {
    param($Sync, [string]$Kind, [string]$Url, [string]$Key, [int]$MinPoster, [string]$Backup, [string]$FilmDir = 'Movies', [string]$TvDir = 'TV')
    # Every film, show and season in Jellyfin, Emby or Plex: its poster (missing, too narrow, wrong
    # shape), a background for films and shows, and a saved copy in <Backup>\Movies or <Backup>\TV.
    function Get-SafeName([string]$Text) { return (($Text -replace '[\\/:*?"<>|]', ' ') -replace '\s+', ' ').Trim() }
    $headers = switch ($Kind) {
        'Plex'  { @{ 'X-Plex-Token' = $Key; 'Accept' = 'application/json' } }
        'Emby'  { @{ 'X-Emby-Token' = $Key; 'Accept' = 'application/json' } }
        default { @{ 'Authorization' = "MediaBrowser Token=`"$Key`""; 'Accept' = 'application/json' } }
    }
    function Get-Json([string]$Path) { return Invoke-RestMethod -Uri "$Url$Path" -Headers $headers -TimeoutSec 120 }
    function Get-HeadSize([string]$ImageUrl) {
        # The picture's size from its first 256 KB (Plex doesn't say how big its posters are).
        $req = [Net.HttpWebRequest]::Create($ImageUrl)
        foreach ($h in $headers.Keys) { if ($h -ne 'Accept') { $req.Headers[$h] = $headers[$h] } }
        $req.AddRange(0, 262143); $req.Timeout = 30000
        $resp = $req.GetResponse()
        try {
            $s = $resp.GetResponseStream(); $buf = New-Object byte[] 262144; $got = 0
            while ($got -lt $buf.Length) { $n = $s.Read($buf, $got, $buf.Length - $got); if ($n -le 0) { break }; $got += $n }
            $part = New-Object byte[] $got; [Array]::Copy($buf, $part, $got)
            return [AcImage]::SizeOf($part)
        } finally { $resp.Close() }
    }
    function Add-Line($Tab, $KindName, $Name, $Group, [string[]]$Problems, $Severity, $Size, $Where, $Copy, $Image, $Page, $Id, $SevOther, $Backdrop) {
        $i = New-Object AcItem
        $i.Kind = $KindName; $i.Tab = $Tab; $i.Name = $Name; $i.Group = $Group; $i.Severity = $Severity
        $i.Problem = if ($Problems.Count) { $Problems -join '; ' } else { 'OK' }
        $i.Where = $Where; $i.ItemId = [string]$Id; $i.Copy = $Copy; $i.SevOther = $SevOther; $i.Page = $Page
        $i.Image = $Image; $i.Backdrop = $Backdrop
        $i.CanSave = [bool]$Image -and $Copy -and -not [IO.File]::Exists($Copy)
        if ($Size) { $i.Width = $Size[0]; $i.Height = $Size[1]; $i.Size = '{0} x {1}' -f $Size[0], $Size[1] }
        [void]$Sync.Items.Add($i)
    }
    function Test-One($KindName, $Name, $Group, $Where, $Id, $Image, $Size, $Backdrop, $Page) {
        $HasBackdrop = [bool]$Backdrop
        # One film, show or season: what is wrong with its pictures.
        $tab = if ($KindName -eq 'Film') { 'Films' } else { 'TV' }
        $copy = $null
        if ($Backup) {
            $file = switch ($KindName) { 'Film' { $Name } 'Show' { $Name } default { "$Group - $Name" } }
            $copy = Join-Path (Join-Path $Backup $(if ($KindName -eq 'Film') { $FilmDir } else { $TvDir })) ((Get-SafeName $file) + '.jpg')
        }
        $problems = New-Object Collections.Generic.List[string]; $sev = 0
        if (-not $Image) {
            # A season without its own poster shows the show's, so it only needs a look.
            if ($KindName -eq 'Season') { $problems.Add('No season poster (uses the show''s)'); $sev = 1 } else { $problems.Add('Missing poster'); $sev = 2 }
            Add-Line $tab $KindName $Name $Group $problems.ToArray() $sev $null $Where $copy $null $Page $Id $sev $Backdrop
            return
        }
        if ($Size) {
            $w = $Size[0]; $h = $Size[1]; $ratio = if ($h) { $w / $h } else { 0 }
            if ($w -lt $MinPoster) { $problems.Add("Small poster ($w x $h)"); $sev = 2 }
            elseif ($ratio -gt 0.8 -or $ratio -lt 0.55) { $problems.Add("Poster isn't poster-shaped"); $sev = [Math]::Max($sev, 1) }
        }
        if ($KindName -ne 'Season' -and -not $HasBackdrop) { $problems.Add('No background picture'); $sev = [Math]::Max($sev, 1) }
        $sevOther = $sev
        if ($copy -and -not [IO.File]::Exists($copy)) { $problems.Add('Not saved in the picture folder'); $sev = [Math]::Max($sev, 1) }
        Add-Line $tab $KindName $Name $Group $problems.ToArray() $sev $Size $Where $copy $Image $Page $Id $sevOther $Backdrop
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if ($Backup -and -not (Test-Path -LiteralPath $Backup)) { $Sync.Errors += "Not found: $Backup" }
        $Sync.Now = "Asking $Kind for the films and shows..."
        if ($Kind -eq 'Plex') {
            $machine = (Get-Json '/').MediaContainer.machineIdentifier
            $sections = @((Get-Json '/library/sections').MediaContainer.Directory | Where-Object { $_.type -in 'movie', 'show' })
            $all = New-Object Collections.Generic.List[object]
            foreach ($sec in $sections) {
                $types = if ($sec.type -eq 'movie') { @(1) } else { @(2, 3) }   # 1 films, 2 shows, 3 seasons
                foreach ($t in $types) { foreach ($m in @((Get-Json "/library/sections/$($sec.key)/all?type=$t").MediaContainer.Metadata)) { if ($m) { $all.Add($m) } } }
            }
            $Sync.Total = $all.Count
            foreach ($m in $all) {
                if ($Sync.Cancel) { break }
                $Sync.Done++; $Sync.Now = $m.title
                $kindName = switch ($m.type) { 'movie' { 'Film' } 'show' { 'Show' } default { 'Season' } }
                $name = if ($kindName -eq 'Film' -and $m.year) { "$($m.title) ($($m.year))" } else { [string]$m.title }
                $group = if ($kindName -eq 'Season') { [string]$m.parentTitle } else { '' }
                # A season's thumb is often its show's; only count it as its own poster when it differs.
                $thumb = [string]$m.thumb
                if ($kindName -eq 'Season' -and $thumb -and $m.parentThumb -and $thumb -eq $m.parentThumb) { $thumb = '' }
                $image = if ($thumb) { "$Url$thumb" } else { $null }
                $size = $null
                if ($image) { try { $size = Get-HeadSize $image } catch { $Sync.Errors += "$($name): $($_.Exception.Message)" } }
                $page = "$Url/web/index.html#!/server/$machine/details?key=" + [Uri]::EscapeDataString("/library/metadata/$($m.ratingKey)")
                $art = if ($m.art) { "$Url$($m.art)" } else { $null }
                Test-One $kindName $name $group '' $m.ratingKey $image $size $art $page
            }
        } else {
            $info = Get-Json '/System/Info'
            $all = Get-Json '/Items?Recursive=true&IncludeItemTypes=Movie,Series,Season&Fields=Path,ProductionYear&EnableImageTypes=Primary,Backdrop'
            $items = @($all.Items)
            $Sync.Total = $items.Count
            foreach ($it in $items) {
                if ($Sync.Cancel) { break }
                $Sync.Done++; $Sync.Now = $it.Name
                $kindName = switch ($it.Type) { 'Movie' { 'Film' } 'Series' { 'Show' } default { 'Season' } }
                $name = if ($kindName -eq 'Film' -and $it.ProductionYear) { "$($it.Name) ($($it.ProductionYear))" } else { [string]$it.Name }
                $group = if ($kindName -eq 'Season') { [string]$it.SeriesName } else { '' }
                $hasPrimary = [bool]($it.ImageTags -and $it.ImageTags.PSObject.Properties['Primary'])
                $image = if ($hasPrimary) { "$Url/Items/$($it.Id)/Images/Primary" } else { $null }
                $size = $null
                if ($image) {
                    try {
                        # Windows PowerShell hands a JSON array on as one object: keep it in a variable first.
                        $imgs = Get-Json "/Items/$($it.Id)/Images"
                        $p = $imgs | Where-Object { $_.ImageType -eq 'Primary' } | Select-Object -First 1
                        if ($p -and $p.Width -and $p.Height) { $size = @([int]$p.Width, [int]$p.Height) }
                    } catch { $Sync.Errors += "$($name): $($_.Exception.Message)" }
                }
                $page = if ($Kind -eq 'Emby') { "$Url/web/index.html#!/item?id=$($it.Id)&serverId=$($info.Id)" } else { "$Url/web/#/details?id=$($it.Id)" }
                $backdrop = if ($it.BackdropImageTags -and @($it.BackdropImageTags).Count) { "$Url/Items/$($it.Id)/Images/Backdrop/0" } else { $null }
                Test-One $kindName $name $group ([string]$it.Path) $it.Id $image $size $backdrop $page
            }
        }
    } catch {
        $Sync.Errors += "$($Kind): $($_.Exception.Message)"
    } finally {
        $Sync.Finished = $true
    }
}

$script:SaveScan = {
    param($Sync, [hashtable]$Headers, [object[]]$Jobs)
    # Downloads each picture from the media server (or copies it, for music) into its file. $Jobs: @{ Url; Path; Item }
    $wc = New-Object Net.WebClient
    try {
        $Sync.Total = $Jobs.Count
        foreach ($j in $Jobs) {
            if ($Sync.Cancel) { break }
            $Sync.Now = $j.Path
            try {
                $dir = [IO.Path]::GetDirectoryName($j.Path)
                if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
                if ($j.Url -match '^https?://') {
                    foreach ($h in $Headers.Keys) { $wc.Headers[$h] = $Headers[$h] }
                    $wc.DownloadFile($j.Url, $j.Path)
                } else {
                    [IO.File]::Copy($j.Url, $j.Path, $true)   # a picture from the music folders
                }
                [void]$Sync.Items.Add($j.Item)
            } catch { $Sync.Errors += "$($j.Path): $($_.Exception.Message)" }
            $Sync.Done++
        }
    } finally {
        $wc.Dispose()
        $Sync.Finished = $true
    }
}
#endregion CHECKS

# ---------------------------------------------------------------------------
#  Help
# ---------------------------------------------------------------------------
$script:HelpText = @'
WHAT IT DOES
Artwork Checker finds albums, artists, films and shows whose pictures are missing or not right, both where your media lives and in your picture folders. Fix them, then scan again.

SOURCES
Sources... says where everything comes from: the music folders and the music picture folder, and for films and TV the media server (Jellyfin, Plex or Emby, with its address and API key or Plex token) and the picture folder for saved posters. Test checks the server answers. Under each picture folder are the names of the folders inside it: Album Pictures and Artist Pics, Movies and TV to begin with; change them to match your own.
Remove folder... takes a music folder off the list for This PC or the NAS, whichever is picked; press Save to keep that. The folder and its files stay where they are.

MUSIC
Scan (on the Music tab) looks through your music folders. Every folder with music files in it is an album; the folder above it is the artist. Music comes from this PC or the NAS, each with its own folders, chosen in Sources... Each album should have cover.jpg in its folder and a copy in <picture folder>\Album Pictures\<Artist>\<Artist> - <Album>.jpg (or in a folder named like the music folder, such as Compilations; the name may end with the year), both exactly 500 x 500. Each artist should have folder.jpg in <picture folder>\Artist Pics\<Artist>, and artist.jpg in its own folder; their size doesn't matter. An album with no cover.jpg whose tracks carry their own cover is marked as worth a look rather than missing.

FILMS AND TV
Films and TV come from your media server (Jellyfin, Plex or Emby, chosen in Sources...), where their posters are kept. Scan on the Films or TV tab checks every film, show and season: a poster at least 600 pixels wide and poster-shaped, a background for films and shows, and a saved copy in the picture folder's Movies or TV folder. Save posters copies the posters that aren't saved yet from the server into those folders.

WHAT THE COLOURS MEAN
Red: missing, unreadable or the wrong size. Amber: worth a look (not poster-shaped, no background, not saved yet, no artist.jpg, or a season using its show's poster). Green: fine.

THE LIST
Problems only hides the ones that are fine. Type in the search box to find an album, artist, film or show. Click a line to see its picture on the right; double-click to open its folder (music) or its page in the media server (films and TV). Export saves the list as a CSV file. It can also save the pictures as files in a folder you choose: on the Music tab the covers (and artist pictures), laid out as Album Pictures\<Artist>\<Artist> - <Album>.jpg and Artist Pics\<Artist>\folder.jpg; on the Films and TV tabs the posters (and backgrounds, ending in " - fanart.jpg"), in Movies and TV folders. The last scan is kept, so it shows again the next time you start.

SIZES
Sources... also sets the cover size (500 x 500) and the smallest poster width (600).

LOOK
The Look button switches between Light, Dark and the same as Windows, from the next start.
'@

function Show-Help {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="660" Height="600" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="22,18,22,16">
    <Button x:Name="HelpClose" DockPanel.Dock="Bottom" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,14,0,0" IsCancel="True" IsDefault="True"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><TextBlock x:Name="HelpText" TextWrapping="Wrap" LineHeight="20"/></ScrollViewer>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = "$script:AppName Help"
    $w.FindName('HelpText').Text = $script:HelpText
    $w.FindName('HelpClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Sources: where the music, films and TV come from, and the picture folders
# ---------------------------------------------------------------------------
# Each server's usual address; change it in Sources... (for example to your NAS).
$script:ServerDefaults = @{ Jellyfin = 'http://localhost:8096'; Emby = 'http://localhost:8096'; Plex = 'http://localhost:32400' }

function Get-ServerHeader([string]$Kind = $script:Settings.ServerKind, [string]$Key = (Get-ServerKey)) {
    switch ($Kind) {
        'Plex'  { return @{ 'X-Plex-Token' = $Key } }
        'Emby'  { return @{ 'X-Emby-Token' = $Key } }
        default { return @{ 'Authorization' = "MediaBrowser Token=`"$Key`"" } }
    }
}
function Get-ServerUrl { return [string]$script:Settings["$($script:Settings.ServerKind)Url"] }
function Get-ServerKey { return [string]$script:Settings["$($script:Settings.ServerKind)Key"] }

function Get-ImageUrl($Item, [switch]$Full) {
    # Jellyfin and Emby can send a smaller JPEG for the preview; Plex sends the picture as it is.
    if ($script:Settings.ServerKind -eq 'Plex') { return $Item.Image }
    if ($Full) { return "$($Item.Image)?format=Jpg&quality=95" }
    return "$($Item.Image)?maxHeight=900&format=Jpg"
}

function Show-RemoveFolderMenu($Button, [Windows.Controls.TextBox]$Box, [Windows.Controls.TextBlock]$Note) {
    <# Remove folder...: a menu of the folders in the box; the one picked comes out of the box. Nothing is removed from
       the disk, and nothing is saved until Save. #>
    $lines = @($Box.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $lines.Count) { $Note.Text = 'There are no folders to remove.'; return }
    $x = @'
<ContextMenu xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             Foreground="{Ink}" MaxWidth="700" MaxHeight="420">
  <ContextMenu.Template>
    <ControlTemplate TargetType="ContextMenu">
      <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="6" Padding="4">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
      </Border>
    </ControlTemplate>
  </ContextMenu.Template>
  <ContextMenu.ItemContainerStyle>
    <Style TargetType="MenuItem">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="MenuItem">
        <Border x:Name="B" Background="Transparent" CornerRadius="4" Padding="10,7"><ContentPresenter ContentSource="Header"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
  </ContextMenu.ItemContainerStyle>
</ContextMenu>
'@
    $menu = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Expand-Xaml $x))))
    $menu.FontSize = $Button.FontSize
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $text = New-Object Windows.Controls.TextBlock      # not plain text: that would take a _ as a shortcut key
        $text.Text = $lines[$i]; $text.TextWrapping = 'Wrap'; $text.MaxWidth = 640
        $item = New-Object Windows.Controls.MenuItem
        $item.Header = $text
        $item.Tag = @{ Index = $i; Folder = $lines[$i]; Box = $Box; Note = $Note }
        $item.Add_Click({
            $t = $this.Tag
            $now = @($t.Box.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($t.Index -ge $now.Count -or $now[$t.Index] -ne $t.Folder) { return }      # the box changed meanwhile
            $left = @(for ($n = 0; $n -lt $now.Count; $n++) { if ($n -ne $t.Index) { $now[$n] } })
            $t.Box.Text = $left -join "`r`n"
            $t.Note.Text = 'Removed from the list. Press Save to keep the change.'
        })
        [void]$menu.Items.Add($item)
    }
    $menu.PlacementTarget = $Button
    $menu.Placement = 'Bottom'
    $Button.ContextMenu = $menu
    $menu.IsOpen = $true
}

function Show-Sources {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="640" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="{Ink}"/></Style>
    <Style TargetType="RadioButton"><Setter Property="Foreground" Value="{Ink}"/><Setter Property="Margin" Value="0,0,20,0"/></Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Background" Value="{Field}"/><Setter Property="Foreground" Value="{Ink}"/><Setter Property="BorderBrush" Value="{Line}"/>
      <Setter Property="CaretBrush" Value="{Ink}"/><Setter Property="Padding" Value="6,4"/>
    </Style>
    <Style x:Key="Head" TargetType="TextBlock"><Setter Property="FontSize" Value="15"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="{Accent}"/></Style>
  </Window.Resources>
  <StackPanel Margin="22,18,22,16">
    <TextBlock Text="Music" Style="{StaticResource Head}"/>
    <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
      <RadioButton x:Name="MPc" Content="This PC" GroupName="Mus"/>
      <RadioButton x:Name="MNas" Content="NAS" GroupName="Mus"/>
    </StackPanel>
    <TextBlock Text="Music folders, one per line (artist folders with album folders inside):" Margin="0,8,0,0" TextWrapping="Wrap"/>
    <TextBox x:Name="FRoots" Height="62" Margin="0,6,0,0" AcceptsReturn="True" VerticalContentAlignment="Top" VerticalScrollBarVisibility="Auto"/>
    <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
      <Button x:Name="FAdd" Content="Add folder..."/>
      <Button x:Name="FRemove" Content="Remove folder..." Margin="0" ContextMenuService.IsEnabled="False"
              ToolTip="Pick a folder to take off this list. The folder and its files stay where they are."/>
    </StackPanel>
    <TextBlock Text="Picture folder (album covers and artist pictures are kept in the two folders named below, inside it):" Margin="0,12,0,4" TextWrapping="Wrap"/>
    <DockPanel><Button x:Name="FMusicPick" Content="..." DockPanel.Dock="Right" Margin="6,0,0,0" Padding="10,4"/><TextBox x:Name="FMusic"/></DockPanel>
    <Grid Margin="0,6,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <TextBlock Text="Covers in" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBox x:Name="FAlbumDir" Grid.Column="1" ToolTip="The folder inside the picture folder for album covers: Covers in\Artist\Artist - Album.jpg"/>
      <TextBlock Grid.Column="2" Text="Artist pictures in" VerticalAlignment="Center" Margin="12,0,8,0"/><TextBox x:Name="FArtistDir" Grid.Column="3" ToolTip="The folder inside the picture folder for artist pictures: Artist pictures in\Artist\folder.jpg"/>
    </Grid>
    <DockPanel Margin="0,12,0,0">
      <TextBox x:Name="FCover" DockPanel.Dock="Right" Width="80"/>
      <CheckBox x:Name="FArtists" Content="Check artist pictures too" VerticalAlignment="Center"/>
      <TextBlock Text="Cover size (square)" Margin="0,0,10,0" VerticalAlignment="Center" HorizontalAlignment="Right"/>
    </DockPanel>

    <Border BorderBrush="{Line}" BorderThickness="0,1,0,0" Margin="0,18,0,14"/>
    <TextBlock Text="Films and TV" Style="{StaticResource Head}"/>
    <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
      <RadioButton x:Name="SJelly" Content="Jellyfin" GroupName="Srv"/>
      <RadioButton x:Name="SPlex" Content="Plex" GroupName="Srv"/>
      <RadioButton x:Name="SEmby" Content="Emby" GroupName="Srv"/>
    </StackPanel>
    <Grid Margin="0,10,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
      <TextBlock Text="Address" VerticalAlignment="Center"/>
      <TextBox x:Name="SUrl" Grid.Column="1" Margin="0,2"/>
      <TextBlock x:Name="SKeyLabel" Grid.Row="1" Text="API key" VerticalAlignment="Center"/>
      <PasswordBox x:Name="SKey" Grid.Row="1" Grid.Column="1" Margin="0,2"/>
    </Grid>
    <DockPanel Margin="0,6,0,0">
      <Button x:Name="STest" Content="Test" DockPanel.Dock="Left" VerticalAlignment="Top"/>
      <TextBlock x:Name="SNote" Foreground="{Soft}" TextWrapping="Wrap" VerticalAlignment="Center"/>
    </DockPanel>
    <TextBlock Text="Picture folder for saved posters (films and TV are kept in the two folders named below, inside it):" Margin="0,12,0,4" TextWrapping="Wrap"/>
    <DockPanel><Button x:Name="FFilmsPick" Content="..." DockPanel.Dock="Right" Margin="6,0,0,0" Padding="10,4"/><TextBox x:Name="FFilms"/></DockPanel>
    <Grid Margin="0,6,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <TextBlock Text="Films in" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBox x:Name="FFilmDir" Grid.Column="1"/>
      <TextBlock Grid.Column="2" Text="TV in" VerticalAlignment="Center" Margin="12,0,8,0"/><TextBox x:Name="FTvDir" Grid.Column="3"/>
    </Grid>
    <DockPanel Margin="0,12,0,0">
      <TextBox x:Name="FMinPoster" DockPanel.Dock="Right" Width="80"/>
      <TextBlock Text="Smallest poster width" Margin="0,0,10,0" VerticalAlignment="Center" HorizontalAlignment="Right"/>
    </DockPanel>

    <DockPanel Margin="0,20,0,0">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="FOk" Content="Save" Style="{StaticResource Accent}" MinWidth="90" IsDefault="True" ToolTip="Save the settings; the window stays open"/>
        <Button x:Name="FCancel" Content="Close" MinWidth="80" Margin="0" IsCancel="True"/>
      </StackPanel>
      <TextBlock x:Name="FSaved" Foreground="{Good}" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,12,0"/>
    </DockPanel>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = 'Sources'
    $roots = $w.FindName('FRoots')
    # This PC and the NAS keep their own folders, so switching loses nothing.
    $mus = @{ From = [string]$script:Settings.MusicFrom; PC = (@($script:Settings.PcRoots) -join "`r`n"); NAS = (@($script:Settings.NasRoots) -join "`r`n") }
    if ($mus.From -ne 'NAS') { $mus.From = 'PC' }
    $roots.Text = $mus[$mus.From]
    $mPc = $w.FindName('MPc'); $mNas = $w.FindName('MNas')
    if ($mus.From -eq 'NAS') { $mNas.IsChecked = $true } else { $mPc.IsChecked = $true }
    $mPc.Add_Checked({ $mus[$mus.From] = $roots.Text; $mus.From = 'PC'; $roots.Text = $mus.PC })
    $mNas.Add_Checked({ $mus[$mus.From] = $roots.Text; $mus.From = 'NAS'; $roots.Text = $mus.NAS })
    $music = $w.FindName('FMusic'); $music.Text = [string]$script:Settings.MusicPictures
    $films = $w.FindName('FFilms'); $films.Text = [string]$script:Settings.FilmPictures
    foreach ($pair in @(@('FAlbumDir', 'AlbumFolder'), @('FArtistDir', 'ArtistFolder'), @('FFilmDir', 'FilmFolder'), @('FTvDir', 'TvFolder'))) { $w.FindName($pair[0]).Text = [string]$script:Settings[$pair[1]] }
    $w.FindName('FArtists').IsChecked = [bool]$script:Settings.CheckArtists
    $w.FindName('FCover').Text = [string]$script:Settings.CoverSize
    $w.FindName('FMinPoster').Text = [string]$script:Settings.MinPoster
    $url = $w.FindName('SUrl'); $key = $w.FindName('SKey'); $note = $w.FindName('SNote'); $keyLabel = $w.FindName('SKeyLabel')
    $radios = @{ Jellyfin = $w.FindName('SJelly'); Plex = $w.FindName('SPlex'); Emby = $w.FindName('SEmby') }

    # Each server keeps its own address and key, so switching between them loses nothing.
    $edit = @{}
    foreach ($k in 'Jellyfin', 'Plex', 'Emby') { $edit[$k] = @{ Url = [string]$script:Settings["${k}Url"]; Key = [string]$script:Settings["${k}Key"] } }
    $state = @{ Kind = [string]$script:Settings.ServerKind }
    $show = {
        $k = $state.Kind
        $url.Text = $edit[$k].Url   # blank until you type it
        $url.ToolTip = "The server's web address, such as $($script:ServerDefaults[$k]) on the server itself, or http://<its address>:$(([uri]$script:ServerDefaults[$k]).Port) from another PC"
        $key.Password = $edit[$k].Key
        $keyLabel.Text = if ($k -eq 'Plex') { 'Plex token' } else { 'API key' }
        $note.Foreground = Get-Brush 'Soft'
        $note.Text = switch ($k) {
            'Plex'  { 'Your Plex token: in Plex Web open any film, ... > Get Info > View XML, and copy the X-Plex-Token from the address.' }
            'Emby'  { "Make an API key in Emby's dashboard: Advanced > API Keys > New." }
            default { "Make an API key in Jellyfin's dashboard: API Keys > +." }
        }
    }
    $keep = { $edit[$state.Kind].Url = $url.Text.Trim().TrimEnd('/'); $edit[$state.Kind].Key = $key.Password }
    $radios[$state.Kind].IsChecked = $true
    & $show
    foreach ($k in $radios.Keys) {
        $radios[$k].Tag = $k
        $radios[$k].Add_Checked({ & $keep; $state.Kind = $this.Tag; & $show })
    }
    $w.FindName('STest').Add_Click({
        & $keep
        $k = $state.Kind; $u = $edit[$k].Url
        if (-not $u) { $note.Foreground = Get-Brush 'Warn'; $note.Text = "Type the server's web address first, such as $($script:ServerDefaults[$k])."; return }
        try {
            $h = Get-ServerHeader $k $edit[$k].Key
            $h['Accept'] = 'application/json'
            if ($k -eq 'Plex') {
                $info = (Invoke-RestMethod -Uri "$u/" -Headers $h -TimeoutSec 10).MediaContainer
                $note.Text = "Connected to $($info.friendlyName), Plex $($info.version)."
            } else {
                $info = Invoke-RestMethod -Uri "$u/System/Info" -Headers $h -TimeoutSec 10
                $note.Text = "Connected to $($info.ServerName), $k $($info.Version)."
            }
            $note.Foreground = Get-Brush 'Good'
        } catch {
            $note.Text = "Couldn't connect: $($_.Exception.Message)"
            $note.Foreground = Get-Brush 'Bad'
        }
    })
    $pick = {
        param([Windows.Controls.TextBox]$Box, [string]$What)
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $What
        if ($Box.Text -and (Test-Path -LiteralPath $Box.Text)) { $dlg.SelectedPath = $Box.Text }
        if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath }
        return $null
    }
    $w.FindName('FAdd').Add_Click({ $p = & $pick $roots 'Choose a music folder'; if ($p) { $roots.Text = (($roots.Text.TrimEnd() + "`r`n" + $p).Trim()) } })
    # Looked up when clicked: FSaved is fetched further down.
    $w.FindName('FRemove').Add_Click({ Show-RemoveFolderMenu $this $roots $w.FindName('FSaved') })
    $w.FindName('FMusicPick').Add_Click({ $p = & $pick $music 'Choose the music picture folder'; if ($p) { $music.Text = $p } })
    $w.FindName('FFilmsPick').Add_Click({ $p = & $pick $films 'Choose the picture folder for saved posters'; if ($p) { $films.Text = $p } })
    # Save keeps the window open, so more can be changed; Close (or Esc) closes it.
    $saved = $w.FindName('FSaved')
    $apply = {
        & $keep
        $old = "$($script:Settings.ServerKind)|$(Get-ServerUrl)"
        $mus[$mus.From] = $roots.Text
        $script:Settings.MusicFrom = $mus.From
        $script:Settings.PcRoots = @($mus.PC -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $script:Settings.NasRoots = @($mus.NAS -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $script:Settings.MusicPictures = $music.Text.Trim()
        $script:Settings.FilmPictures = $films.Text.Trim()
        # A folder name only (no \ or other characters Windows won't take); blank keeps the one before.
        foreach ($pair in @(@('FAlbumDir', 'AlbumFolder'), @('FArtistDir', 'ArtistFolder'), @('FFilmDir', 'FilmFolder'), @('FTvDir', 'TvFolder'))) {
            $t = $w.FindName($pair[0]).Text.Trim()
            if ($t -and $t.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0) { $script:Settings[$pair[1]] = $t } else { $w.FindName($pair[0]).Text = [string]$script:Settings[$pair[1]] }
        }
        $script:Settings.CheckArtists = [bool]$w.FindName('FArtists').IsChecked
        foreach ($pair in @(@('CoverSize', 'FCover'), @('MinPoster', 'FMinPoster'))) {
            $t = $w.FindName($pair[1]).Text.Trim()
            if ($t -match '^\d+$' -and [int]$t -gt 0) { $script:Settings[$pair[0]] = [int]$t }
        }
        $script:Settings.ServerKind = $state.Kind
        foreach ($k in 'Jellyfin', 'Plex', 'Emby') { $script:Settings["${k}Url"] = $edit[$k].Url; $script:Settings["${k}Key"] = $edit[$k].Key }
        Save-AppSetting
        # Films and TV from another server: the old lines don't belong to it, so they go.
        if ($old -ne "$($script:Settings.ServerKind)|$(Get-ServerUrl)") {
            foreach ($i in @($script:Items | Where-Object { $_.Tab -ne 'Music' })) { [void]$script:Items.Remove($i) }
            Save-Results
        }
        Update-View
        Set-Status "Saved. Films and TV come from $($script:Settings.ServerKind). Scan again to use the new settings."
        $saved.Text = "Saved at $((Get-Date).ToString('HH:mm:ss'))."
    }
    $w.FindName('FOk').Add_Click({ & $apply })
    $w.FindName('FCancel').Add_Click({ $w.Close() })
    foreach ($c in @($roots, $music, $films, $url, $w.FindName('FCover'), $w.FindName('FMinPoster'))) { $c.Add_TextChanged({ $saved.Text = '' }) }
    $key.Add_PasswordChanged({ $saved.Text = '' })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Main window
# ---------------------------------------------------------------------------
$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1230" Height="740" MinWidth="760" MinHeight="420" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13" Background="{Page}" Foreground="{Ink}">
  <Window.Resources>
STYLES
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="{Ink}"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
    <Style x:Key="Tab" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{Soft}"/><Setter Property="FontSize" Value="14"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,0,4,0"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <Border x:Name="B" Background="Transparent" BorderThickness="0,0,0,3" BorderBrush="Transparent" Padding="14,7,14,6" CornerRadius="4,4,0,0">
          <ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/><Setter Property="Foreground" Value="{Ink}"/><Setter Property="FontWeight" Value="SemiBold"/>
          </Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="ProblemText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{Good}"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="ToolTip" Value="{Binding Problem}"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Severity}" Value="1"><Setter Property="Foreground" Value="{Warn}"/></DataTrigger>
        <DataTrigger Binding="{Binding Severity}" Value="2"><Setter Property="Foreground" Value="{Bad}"/><Setter Property="FontWeight" Value="SemiBold"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Cell" TargetType="TextBlock"><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="{Card}"/><Setter Property="Foreground" Value="{Soft}"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="8,7"/><Setter Property="BorderBrush" Value="{Line}"/><Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="{Card}"/><Setter Property="Foreground" Value="{Ink}"/>
      <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{Hover}"/></Trigger></Style.Triggers>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="8,5"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridCell">
        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"><ContentPresenter VerticalAlignment="Center"/></Border>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{Select}"/><Setter Property="Foreground" Value="{Ink}"/></Trigger></Style.Triggers>
    </Style>
    <Style TargetType="ProgressBar"><Setter Property="Foreground" Value="{Accent}"/><Setter Property="Background" Value="{Line}"/><Setter Property="BorderThickness" Value="0"/></Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Bottom" Background="{Card}" BorderBrush="{Line}" BorderThickness="0,1,0,0" Padding="18,10">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="BtnExport" Content="Export..." ToolTip="Save the list as a CSV file, or the covers, artist pictures, posters and backgrounds as picture files"/>
          <Button x:Name="BtnLook"/>
          <Button x:Name="BtnHelp" Content="Help"/>
          <Button x:Name="BtnAbout" Content="About" Margin="0"/>
        </StackPanel>
        <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Foreground="{Soft}"/>
      </DockPanel>
    </Border>
    <ProgressBar x:Name="Progress" DockPanel.Dock="Bottom" Height="3" Visibility="Hidden"/>
    <DockPanel DockPanel.Dock="Top" Margin="18,14,18,0">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="BtnSave" Content="Save posters" Visibility="Collapsed" ToolTip="Copy the posters that aren't saved yet from the media server into Movies &amp; TV"/>
        <Button x:Name="BtnSources" Content="Sources..." ToolTip="Where the music, films and TV come from, and the picture folders"/>
        <Button x:Name="BtnScan" Content="Scan" Style="{StaticResource Accent}" MinWidth="90" Margin="0"/>
      </StackPanel>
      <TextBlock x:Name="TxtSummary" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
    </DockPanel>
    <Border DockPanel.Dock="Top" BorderBrush="{Line}" BorderThickness="0,0,0,1" Margin="18,10,18,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" Margin="0,0,0,6">
          <CheckBox x:Name="ChkProblems" Content="Problems only" Margin="0,0,14,0" IsChecked="True"/>
          <Grid Width="240">
            <TextBox x:Name="TxtSearch" ToolTip="Find an album, artist, film or show"/>
            <TextBlock x:Name="TxtHint" Text="Search" Foreground="{Soft}" Margin="9,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
          </Grid>
        </StackPanel>
        <StackPanel Orientation="Horizontal">
          <RadioButton x:Name="TabMusic" Style="{StaticResource Tab}" GroupName="Tabs" IsChecked="True"/>
          <RadioButton x:Name="TabFilms" Style="{StaticResource Tab}" GroupName="Tabs"/>
          <RadioButton x:Name="TabTV" Style="{StaticResource Tab}" GroupName="Tabs"/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Grid Margin="18,12,18,12">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="300"/></Grid.ColumnDefinitions>
      <DataGrid x:Name="Grid" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" HeadersVisibility="Column" RowHeaderWidth="0"
                Background="{Card}" RowBackground="{Card}" Foreground="{Ink}" BorderBrush="{Line}" BorderThickness="1"
                GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="{Line}" CanUserResizeRows="False" EnableRowVirtualization="True">
        <DataGrid.Columns>
          <DataGridTextColumn Header="Problem" Width="3*" Binding="{Binding Problem}" ElementStyle="{StaticResource ProblemText}" SortMemberPath="Severity"/>
          <DataGridTextColumn Header="Name" Width="1.8*" Binding="{Binding Name}" ElementStyle="{StaticResource Cell}"/>
          <DataGridTextColumn x:Name="ColGroup" Header="Artist" Width="1.3*" Binding="{Binding Group}" ElementStyle="{StaticResource Cell}"/>
          <DataGridTextColumn Header="Type" Width="70" Binding="{Binding Kind}"/>
          <DataGridTextColumn Header="Size" Width="100" Binding="{Binding Size}" SortMemberPath="Width"/>
        </DataGrid.Columns>
      </DataGrid>
      <Border Grid.Column="1" Margin="12,0,0,0" Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="14">
        <DockPanel>
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
            <Button x:Name="BtnOpen" Content="Open folder" IsEnabled="False"/>
            <Button x:Name="BtnImage" Content="Open picture" Margin="0" IsEnabled="False"/>
          </StackPanel>
          <TextBlock x:Name="TxtWhere" DockPanel.Dock="Bottom" Foreground="{Soft}" TextWrapping="Wrap" FontSize="12" Margin="0,8,0,0"/>
          <TextBlock x:Name="TxtPick" DockPanel.Dock="Bottom" TextWrapping="Wrap" FontWeight="SemiBold" Margin="0,8,0,0"/>
          <Grid>
            <TextBlock x:Name="TxtNoPic" Text="Click a line to see its picture." Foreground="{Soft}" TextWrapping="Wrap" HorizontalAlignment="Center" VerticalAlignment="Center" TextAlignment="Center"/>
            <Image x:Name="Preview" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
          </Grid>
        </DockPanel>
      </Border>
    </Grid>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Set-Status([string]$Text, [string]$Tone = 'Soft') {
    $script:UI.TxtStatus.Text = $Text
    $script:UI.TxtStatus.Foreground = Get-Brush $Tone
}

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action }
    catch { Write-AppLog "Error: $($_.Exception.Message)"; [void](Show-AppMessage "Something went wrong:`n$($_.Exception.Message)`n`nDetails are in $script:LogPath") }
}

# ---------------------------------------------------------------------------
#  The list
# ---------------------------------------------------------------------------
$script:Items = New-Object Collections.ObjectModel.ObservableCollection[AcItem]
$script:ResultsPath = Join-Path $script:DataDir 'results.json'

function Get-CurrentTab {
    if ($script:UI.TabFilms.IsChecked) { return 'Films' }
    if ($script:UI.TabTV.IsChecked) { return 'TV' }
    return 'Music'
}

function Update-Counts {
    foreach ($t in 'Music', 'Films', 'TV') {
        $all = @($script:Items | Where-Object { $_.Tab -eq $t })
        $bad = @($all | Where-Object { $_.Severity -gt 0 }).Count
        $label = if ($t -eq 'TV') { 'TV' } else { $t }
        $script:UI["Tab$t"].Content = if ($all.Count) { "$label  ($bad)" } else { $label }
        $script:UI["Tab$t"].ToolTip = if ($all.Count) { "$bad of $($all.Count) need a look" } else { 'Not scanned yet' }
    }
    $tab = Get-CurrentTab
    $all = @($script:Items | Where-Object { $_.Tab -eq $tab })
    $red = @($all | Where-Object { $_.Severity -eq 2 }).Count
    $amber = @($all | Where-Object { $_.Severity -eq 1 }).Count
    $what = switch ($tab) { 'Music' { 'albums and artists' } 'Films' { 'films' } default { 'shows and seasons' } }
    $script:UI.TxtSummary.Text = if (-not $all.Count) {
        if ($tab -eq 'Music') { 'Music not scanned yet. Press Scan.' }
        elseif (-not (Get-ServerKey)) { "Films and TV are checked in $($script:Settings.ServerKind). Press Sources... to add its address and key." }
        else { "$tab not scanned yet. Press Scan." }
    } elseif ($red + $amber) { "$red missing or poor, $amber worth a look, in $($all.Count) $what" } else { "All $($all.Count) $what look fine" }
    $script:UI.TxtSummary.Foreground = Get-Brush $(if ($red) { 'Bad' } else { 'Ink' })
}

function Update-View {
    $tab = Get-CurrentTab
    $problems = [bool]$script:UI.ChkProblems.IsChecked
    $q = $script:UI.TxtSearch.Text.Trim()
    $view = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
    $test = {
        param($i)
        if ($i.Tab -ne $tab) { return $false }
        if ($problems -and $i.Severity -eq 0) { return $false }
        if ($q -and -not (($i.Name -like "*$q*") -or ($i.Group -like "*$q*") -or ($i.Problem -like "*$q*"))) { return $false }
        return $true
    }.GetNewClosure()
    $view.Filter = [Predicate[object]]$test
    $script:UI.ColGroup.Header = if ($tab -eq 'Music') { 'Artist' } elseif ($tab -eq 'TV') { 'Show' } else { '' }
    $script:UI.ColGroup.Visibility = if ($tab -eq 'Films') { 'Collapsed' } else { 'Visible' }
    $script:UI.BtnOpen.Content = if ($tab -eq 'Music') { 'Open folder' } else { "Open in $($script:Settings.ServerKind)" }
    $script:UI.BtnSave.Visibility = if ($tab -eq 'Music') { 'Collapsed' } else { 'Visible' }
    $script:UI.BtnSave.IsEnabled = [bool]@($script:Items | Where-Object { $_.Tab -eq $tab -and $_.CanSave }).Count
    Update-Counts
}

function Save-Results {
    try { @($script:Items) | ConvertTo-Json -Depth 3 -Compress | Set-Content -LiteralPath $script:ResultsPath -Encoding UTF8 }
    catch { Write-AppLog "results.json couldn't be saved: $($_.Exception.Message)" }
}

function Read-Results {
    if (-not (Test-Path -LiteralPath $script:ResultsPath)) { return }
    try {
        $saved = Get-Content -LiteralPath $script:ResultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in $saved) {
            $i = New-Object AcItem
            foreach ($p in 'Kind', 'Tab', 'Name', 'Group', 'Problem', 'Image', 'Size', 'Where', 'ItemId', 'Copy', 'Page', 'Backdrop') { $i.$p = [string]$r.$p }
            $i.Severity = [int]$r.Severity; $i.Width = [int]$r.Width; $i.Height = [int]$r.Height; $i.SevOther = [int]$r.SevOther
            $i.CanSave = [bool]$r.CanSave -and $i.Copy -and -not [IO.File]::Exists($i.Copy)
            $script:Items.Add($i)
        }
    } catch { Write-AppLog "results.json couldn't be read: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  Picture on the right
# ---------------------------------------------------------------------------
function Get-ServerBytes([string]$Url) {
    $wc = New-Object Net.WebClient
    $h = Get-ServerHeader
    foreach ($k in $h.Keys) { $wc.Headers.Add($k, $h[$k]) }
    try { return $wc.DownloadData($Url) } finally { $wc.Dispose() }
}

function Show-Preview {
    $i = $script:UI.Grid.SelectedItem
    $ui = $script:UI
    $ui.Preview.Source = $null
    $ui.BtnOpen.IsEnabled = $false; $ui.BtnImage.IsEnabled = $false
    if (-not ($i -is [AcItem])) { $ui.TxtPick.Text = ''; $ui.TxtWhere.Text = ''; $ui.TxtNoPic.Text = 'Click a line to see its picture.'; return }
    $ui.TxtPick.Text = $i.Name + $(if ($i.Size) { "  ·  $($i.Size)" })
    $ui.TxtWhere.Text = $i.Where
    $ui.BtnOpen.IsEnabled = [bool]($i.Where -or $i.Page)
    $ui.TxtNoPic.Text = if ($i.Image) { 'Loading...' } else { 'No picture' }
    if (-not $i.Image) { return }
    try {
        $bytes = if ($i.Tab -eq 'Music') { [IO.File]::ReadAllBytes($i.Image) }
                 elseif ($i.Copy -and [IO.File]::Exists($i.Copy)) { [IO.File]::ReadAllBytes($i.Copy) }
                 else { Get-ServerBytes (Get-ImageUrl $i) }
        $img = New-Object Windows.Media.Imaging.BitmapImage
        $img.BeginInit(); $img.StreamSource = New-Object IO.MemoryStream (, $bytes); $img.CacheOption = 'OnLoad'; $img.DecodePixelHeight = 600; $img.EndInit(); $img.Freeze()
        $ui.Preview.Source = $img
        $ui.TxtNoPic.Text = ''
        $ui.BtnImage.IsEnabled = $true
    } catch { $ui.TxtNoPic.Text = "Can't show the picture: $($_.Exception.Message)" }
}

function Open-Item([switch]$Picture) {
    $i = $script:UI.Grid.SelectedItem
    if (-not ($i -is [AcItem])) { return }
    if ($i.Tab -eq 'Music') {
        if ($Picture -and $i.Image) { Start-Process -FilePath $i.Image }
        elseif ($i.Where -and (Test-Path -LiteralPath $i.Where)) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($i.Where)`"" }
        return
    }
    if ($Picture) {
        # The saved copy, else a copy from the server in the temp folder (the picture needs the key).
        $file = $i.Copy
        if (-not ($file -and [IO.File]::Exists($file))) {
            $file = Join-Path $env:TEMP "Artwork Checker $($i.ItemId).jpg"
            [IO.File]::WriteAllBytes($file, (Get-ServerBytes (Get-ImageUrl $i -Full)))
        }
        Start-Process -FilePath $file
        return
    }
    if ($i.Page) { Start-Process $i.Page }
}

# ---------------------------------------------------------------------------
#  Scanning
# ---------------------------------------------------------------------------
$script:Job = $null

function Start-Scan {
    if ($script:Job) {
        $script:Job.Sync.Cancel = $true
        Set-Status 'Stopping...'
        return
    }
    $tab = Get-CurrentTab
    $sync = [hashtable]::Synchronized(@{ Items = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Done = 0; Total = 0; Now = ''; Finished = $false; Cancel = $false; Errors = @() })
    $ps = [PowerShell]::Create()
    if ($tab -eq 'Music') {
        $roots = @(Get-MusicRoots)
        if (-not $roots.Count) { Show-Sources; return }
        [void]$ps.AddScript($script:MusicScan).AddArgument($sync).AddArgument([string[]]$roots).AddArgument([string]$script:Settings.MusicPictures).AddArgument([int]$script:Settings.CoverSize).AddArgument([bool]$script:Settings.CheckArtists).AddArgument([string]$script:Settings.AlbumFolder).AddArgument([string]$script:Settings.ArtistFolder)
        $tabs = @('Music')
    } else {
        if (-not (Get-ServerUrl) -or -not (Get-ServerKey)) { Show-Sources; if (-not (Get-ServerUrl) -or -not (Get-ServerKey)) { return } }
        [void]$ps.AddScript($script:ServerScan).AddArgument($sync).AddArgument([string]$script:Settings.ServerKind).AddArgument((Get-ServerUrl)).AddArgument((Get-ServerKey)).AddArgument([int]$script:Settings.MinPoster).AddArgument([string]$script:Settings.FilmPictures).AddArgument([string]$script:Settings.FilmFolder).AddArgument([string]$script:Settings.TvFolder)
        $tabs = @('Films', 'TV')
    }
    # The old lines for what is being scanned go; the rest stay.
    foreach ($old in @($script:Items | Where-Object { $tabs -contains $_.Tab })) { [void]$script:Items.Remove($old) }
    $script:Job = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Sync = $sync; Tabs = $tabs; Started = Get-Date; Taken = 0; Mode = 'Scan' }
    $script:UI.BtnScan.Content = 'Stop'
    $script:UI.Progress.Visibility = 'Visible'
    $script:UI.Progress.IsIndeterminate = $true
    Update-View
    Write-AppLog "Scan started: $($tabs -join ', ')"
}

function Start-Save {
    <# Copies the posters that aren't saved yet (this tab) from the media server into the picture folder, in the background. #>
    if ($script:Job) { return }
    $tab = Get-CurrentTab
    $todo = @($script:Items | Where-Object { $_.Tab -eq $tab -and $_.CanSave })
    if (-not $todo.Count) { Set-Status 'Every poster on this tab is saved already.'; return }
    if (-not (Show-AppMessage "Save $($todo.Count) poster$(if ($todo.Count -ne 1) { 's' }) from $($script:Settings.ServerKind) into $($script:Settings.FilmPictures)?`n`nExisting files are left as they are." -YesText 'Save' -NoText 'Cancel')) { return }
    $jobs = @($todo | ForEach-Object { @{ Url = (Get-ImageUrl $_ -Full); Path = $_.Copy; Item = $_ } })
    $sync = [hashtable]::Synchronized(@{ Items = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Done = 0; Total = 0; Now = ''; Finished = $false; Cancel = $false; Errors = @() })
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:SaveScan).AddArgument($sync).AddArgument((Get-ServerHeader)).AddArgument([object[]]$jobs)
    $script:Job = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Sync = $sync; Tabs = @($tab); Started = Get-Date; Taken = 0; Mode = 'Save'; Folder = $script:Settings.FilmPictures }
    $script:UI.BtnScan.Content = 'Stop'
    $script:UI.BtnSave.IsEnabled = $false
    $script:UI.Progress.Visibility = 'Visible'
    Write-AppLog "Saving $($jobs.Count) posters"
}

function Update-Scan {
    $j = $script:Job
    if (-not $j) { return }
    $s = $j.Sync
    $new = @()
    [Threading.Monitor]::Enter($s.Items.SyncRoot)
    try { if ($s.Items.Count -gt $j.Taken) { $new = $s.Items.GetRange($j.Taken, $s.Items.Count - $j.Taken).ToArray(); $j.Taken = $s.Items.Count } }
    finally { [Threading.Monitor]::Exit($s.Items.SyncRoot) }
    if ($j.Mode -eq 'Save') {
        # A saved poster: take "Not saved" off its line.
        foreach ($i in @($new | Where-Object { $_ })) {
            $i.CanSave = $false
            $i.Problem = (($i.Problem -split '; ') | Where-Object { $_ -ne 'Not saved in the picture folder' }) -join '; '
            if (-not $i.Problem) { $i.Problem = 'OK' }
            $i.Severity = $i.SevOther
        }
        if ($new.Count) { [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items).Refresh() }
    } else {
        foreach ($i in $new) { $script:Items.Add($i) }
    }
    if ($s.Total) { $script:UI.Progress.IsIndeterminate = $false; $script:UI.Progress.Maximum = $s.Total; $script:UI.Progress.Value = $s.Done }
    $where = [string]$s.Now
    if ($where.Length -gt 90) { $where = '...' + $where.Substring($where.Length - 87) }
    Set-Status ("{0}: {1} {2}  ·  {3}" -f $(if ($j.Mode -eq 'Save') { 'Saving' } else { 'Scanning' }), $j.Taken, $(if ($j.Mode -eq 'Save') { 'saved' } else { 'checked' }), $where)
    if ($new.Count) { Update-Counts }
    if (-not $s.Finished) { return }
    try { $j.PS.EndInvoke($j.Handle) } catch { Write-AppLog "Scan: $($_.Exception.Message)" }
    foreach ($e in @($j.PS.Streams.Error)) { Write-AppLog "Scan error: $e" }
    $j.PS.Dispose()
    $script:Job = $null
    $script:UI.BtnScan.Content = 'Scan'
    $script:UI.Progress.Visibility = 'Hidden'
    Update-View
    Save-Results
    $secs = [int]((Get-Date) - $j.Started).TotalSeconds
    $errs = @($s.Errors)
    foreach ($e in $errs) { Write-AppLog "Scan problem: $e" }
    $msg = if ($j.Mode -eq 'Save') { "Saved $($s.Done - @($s.Errors).Count) picture$(if ($s.Done -ne 1) { 's' }) into $($j.Folder)." }
           elseif ($s.Cancel) { "Stopped after $($j.Taken) checked." } else { "Scan finished: $($j.Taken) checked in $secs s, at $((Get-Date).ToString('HH:mm'))." }
    if ($errs.Count) { Set-Status "$msg $($errs.Count) couldn't be read: $($errs[0])" 'Warn' } else { Set-Status $msg }
    Write-AppLog $msg
}

function Export-List {
    <# The list as a CSV file, or the pictures as files in a folder of your choice:
       Music: covers (and artist pictures) from the music folders, laid out like the picture folder.
       Films and TV: posters (and backgrounds) from the media server. #>
    $tab = Get-CurrentTab
    $music = $tab -eq 'Music'
    $view = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="580" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
    <Style TargetType="RadioButton"><Setter Property="Foreground" Value="{Ink}"/><Setter Property="Margin" Value="0,0,0,8"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="{Ink}"/></Style>
  </Window.Resources>
  <StackPanel Margin="22,18,22,16">
    <TextBlock x:Name="EHead" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,12"/>
    <RadioButton x:Name="EPosters" GroupName="What" IsChecked="True"/>
    <RadioButton x:Name="EBoth" GroupName="What"/>
    <RadioButton x:Name="EList" Content="The list, as a CSV file" GroupName="What"/>
    <TextBlock x:Name="EFolderLabel" Margin="0,8,0,4" TextWrapping="Wrap"/>
    <DockPanel x:Name="EFolderRow"><Button x:Name="EPick" Content="..." DockPanel.Dock="Right" Margin="6,0,0,0" Padding="10,4"/><TextBox x:Name="EFolder"/></DockPanel>
    <CheckBox x:Name="EOverwrite" Content="Replace pictures that are already there" Margin="0,12,0,0"/>
    <TextBlock x:Name="ENote" Foreground="{Soft}" TextWrapping="Wrap" Margin="0,10,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="EOk" Content="Export" Style="{StaticResource Accent}" MinWidth="90" IsDefault="True"/>
      <Button x:Name="ECancel" Content="Cancel" MinWidth="80" Margin="0" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = 'Export'
    $box = $w.FindName('EFolder')
    $mine = @($script:Items | Where-Object { $_.Tab -eq $tab })
    if ($music) {
        $w.FindName('EHead').Text = 'Export music pictures'
        $w.FindName('EPosters').Content = 'Album covers, as picture files'
        $w.FindName('EBoth').Content = 'Album covers and artist pictures'
        $w.FindName('EFolderLabel').Text = "Save into ($($script:Settings.AlbumFolder)\<Artist>\<Artist> - <Album>.jpg and $($script:Settings.ArtistFolder)\<Artist>\folder.jpg are made inside it):"
        $box.Text = if ($script:Settings.MusicPictures) { [string]$script:Settings.MusicPictures } else { [Environment]::GetFolderPath('MyPictures') }
        $w.FindName('ENote').Text = if ($mine.Count) { "The covers are copied from each album folder (cover.jpg) and the artist pictures from each artist folder (artist.jpg)." } else { 'Scan this tab first: no albums have been found yet.' }
    } else {
        $w.FindName('EHead').Text = "Export $tab from $($script:Settings.ServerKind)"
        $w.FindName('EPosters').Content = 'Posters, as picture files'
        $w.FindName('EBoth').Content = 'Posters and backgrounds (backgrounds end in " - fanart.jpg")'
        $w.FindName('EFolderLabel').Text = "Save into ($($script:Settings.FilmFolder) and $($script:Settings.TvFolder) folders are made inside it):"
        $box.Text = if ($script:Settings.FilmPictures) { [string]$script:Settings.FilmPictures } else { [Environment]::GetFolderPath('MyPictures') }
        $withPic = @($mine | Where-Object { $_.Image })
        $w.FindName('ENote').Text = if ($withPic.Count) { "$($withPic.Count) on this tab have a poster in $($script:Settings.ServerKind)." } else { 'Scan this tab first: nothing has been read from the server yet.' }
    }
    $rows = @($w.FindName('EFolderLabel'), $w.FindName('EFolderRow'), $w.FindName('EOverwrite'))
    $w.FindName('EList').Add_Checked({ foreach ($r in $rows) { $r.IsEnabled = $false } })
    foreach ($n in 'EPosters', 'EBoth') { $w.FindName($n).Add_Checked({ foreach ($r in $rows) { $r.IsEnabled = $true } }) }
    $w.FindName('EPick').Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose where to save the pictures'
        if ($box.Text -and (Test-Path -LiteralPath $box.Text)) { $dlg.SelectedPath = $box.Text }
        if ($dlg.ShowDialog() -eq 'OK') { $box.Text = $dlg.SelectedPath }
    })
    $script:ExportGo = $false
    $w.FindName('EOk').Add_Click({ $script:ExportGo = $true; $w.Close() })
    $w.FindName('ECancel').Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
    if (-not $script:ExportGo) { return }
    $what = if ($w.FindName('EList').IsChecked) { 'List' } elseif ($w.FindName('EBoth').IsChecked) { 'Both' } else { 'Pictures' }
    $folder = $box.Text.Trim()
    $overwrite = [bool]$w.FindName('EOverwrite').IsChecked

    if ($what -eq 'List') {
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'CSV file (*.csv)|*.csv'
        $dlg.FileName = "Artwork $tab $((Get-Date).ToString('yyyy-MM-dd')).csv"
        if (-not $dlg.ShowDialog($script:Window)) { return }
        @($view) | Select-Object Tab, Kind, Name, Group, Problem, Size, Where | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
        Set-Status "Saved $($dlg.FileName)"
        return
    }

    if ($script:Job) { Set-Status 'Wait for the scan to finish first.'; return }
    if (-not $folder) { return }
    $safe = { param([string]$t) (($t -replace '[\\/:*?"<>|]', ' ') -replace '\s+', ' ').Trim() }
    $firstPic = {
        # The first of these pictures that is in the folder.
        param([string]$Dir, [string[]]$Names)
        foreach ($n in $Names) { foreach ($e in '.jpg', '.jpeg', '.png') { $f = Join-Path $Dir "$n$e"; if ([IO.File]::Exists($f)) { return $f } } }
        return $null
    }
    $jobs = New-Object Collections.Generic.List[object]
    Set-Status 'Finding the pictures to export...'
    foreach ($i in $mine) {
        if ($music) {
            # Music: <folder>\<AlbumFolder>\<Artist>\<Artist> - <Album>.jpg and <folder>\<ArtistFolder>\<Artist>\folder.jpg
            if ($i.Kind -eq 'Album' -and $i.Group) {
                $src = & $firstPic $i.Where @('cover', 'folder', 'front')
                $path = Join-Path (Join-Path (Join-Path $folder $script:Settings.AlbumFolder) (& $safe $i.Group)) ((& $safe "$($i.Group) - $($i.Name)") + [IO.Path]::GetExtension("$src").ToLower())
                if ($src -and ($overwrite -or -not [IO.File]::Exists($path))) { $jobs.Add(@{ Url = $src; Path = $path; Item = $null }) }
            } elseif ($i.Kind -eq 'Artist' -and $what -eq 'Both') {
                $src = & $firstPic $i.Where @('artist', 'folder')
                $path = Join-Path (Join-Path (Join-Path $folder $script:Settings.ArtistFolder) (& $safe $i.Name)) ('folder' + [IO.Path]::GetExtension("$src").ToLower())
                if ($src -and ($overwrite -or -not [IO.File]::Exists($path))) { $jobs.Add(@{ Url = $src; Path = $path; Item = $null }) }
            }
            continue
        }
        # Films and TV: <folder>\<FilmFolder>\<Film (Year)>.jpg, <folder>\<TvFolder>\<Show>.jpg and <Show> - <Season>.jpg
        $sub = if ($i.Kind -eq 'Film') { $script:Settings.FilmFolder } else { $script:Settings.TvFolder }
        $base = Join-Path (Join-Path $folder $sub) (& $safe $(if ($i.Kind -eq 'Season') { "$($i.Group) - $($i.Name)" } else { $i.Name }))
        if ($i.Image) {
            $path = "$base.jpg"
            if ($overwrite -or -not [IO.File]::Exists($path)) {
                $jobs.Add(@{ Url = (Get-ImageUrl $i -Full); Path = $path; Item = $(if ($i.Copy -and $path -eq $i.Copy) { $i } else { $null }) })
            }
        }
        if ($what -eq 'Both' -and $i.Backdrop) {
            $path = "$base - fanart.jpg"
            $url = if ($script:Settings.ServerKind -eq 'Plex') { $i.Backdrop } else { "$($i.Backdrop)?format=Jpg&quality=95" }
            if ($overwrite -or -not [IO.File]::Exists($path)) { $jobs.Add(@{ Url = $url; Path = $path; Item = $null }) }
        }
    }
    if (-not $jobs.Count) { Set-Status 'Nothing to export: every picture is already there (tick Replace to save them again).'; return }
    $sync = [hashtable]::Synchronized(@{ Items = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Done = 0; Total = 0; Now = ''; Finished = $false; Cancel = $false; Errors = @() })
    $ps = [PowerShell]::Create()
    $headers = if ($music) { @{} } else { Get-ServerHeader }
    [void]$ps.AddScript($script:SaveScan).AddArgument($sync).AddArgument($headers).AddArgument([object[]]$jobs.ToArray())
    $script:Job = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Sync = $sync; Tabs = @($tab); Started = Get-Date; Taken = 0; Mode = 'Save'; Folder = $folder }
    $script:UI.BtnScan.Content = 'Stop'
    $script:UI.Progress.Visibility = 'Visible'
    Write-AppLog "Exporting $($jobs.Count) pictures to $folder"
}

try {
    $window = New-XamlWindow $mainXaml
    $script:Window = $window
    $window.Title = "$script:AppName v$script:AppVersion"
    $icon = Get-AssetImage 'Artwork-Checker.ico'
    if ($icon) { $window.Icon = $icon }
    $ui = @{}
    foreach ($n in 'BtnSave', 'BtnSources', 'BtnScan', 'BtnExport', 'BtnLook', 'BtnHelp', 'BtnAbout', 'TxtStatus', 'TxtSummary', 'Progress',
                   'ChkProblems', 'TxtSearch', 'TxtHint', 'TabMusic', 'TabFilms', 'TabTV', 'Grid', 'ColGroup', 'BtnOpen', 'BtnImage', 'TxtWhere', 'TxtPick', 'TxtNoPic', 'Preview') { $ui[$n] = $window.FindName($n) }
    $script:UI = $ui
    $setLook = { $ui.BtnLook.Content = switch ($script:Settings.Look) { 'Dark' { 'Look: Dark' } 'System' { 'Look: Auto' } default { 'Look: Light' } } }
    & $setLook
    $ui.BtnLook.ToolTip = 'Light, dark, or the same as Windows. Used the next time the app starts.'
    $ui.BtnLook.Add_Click({
        $script:Settings.Look = switch ($script:Settings.Look) { 'Light' { 'Dark' } 'Dark' { 'System' } default { 'Light' } }
        Save-AppSetting; & $setLook
        Set-Status 'Look saved. It is used the next time the app starts.'
    })
    $ui.BtnHelp.Add_Click({ Show-Help })
    $ui.BtnAbout.Add_Click({ Show-About -Owner $window })
    $ui.BtnSources.Add_Click({ Invoke-Safely { Show-Sources } })
    $ui.BtnSave.Add_Click({ Invoke-Safely { Start-Save } })
    $ui.BtnScan.Add_Click({ Invoke-Safely { Start-Scan } })
    $ui.BtnExport.Add_Click({ Invoke-Safely { Export-List } })
    $ui.BtnOpen.Add_Click({ Invoke-Safely { Open-Item } })
    $ui.BtnImage.Add_Click({ Invoke-Safely { Open-Item -Picture } })
    foreach ($t in 'TabMusic', 'TabFilms', 'TabTV') { $ui[$t].Add_Checked({ $script:Settings.Tab = (Get-CurrentTab); Update-View }) }
    $ui.ChkProblems.Add_Click({ Update-View })
    $ui.TxtSearch.Add_TextChanged({ $ui.TxtHint.Visibility = if ($ui.TxtSearch.Text) { 'Collapsed' } else { 'Visible' }; Update-View })
    $ui.Grid.Add_SelectionChanged({ Invoke-Safely { Show-Preview } })
    $ui.Grid.Add_MouseDoubleClick({ Invoke-Safely { Open-Item } })
    $ui.Grid.ItemsSource = $script:Items
    # Red first, then amber, then the rest; within each, by type and name.
    $sortView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
    foreach ($sd in @(@('Severity', 'Descending'), @('Kind', 'Ascending'), @('Group', 'Ascending'), @('Name', 'Ascending'))) {
        $sortView.SortDescriptions.Add((New-Object ComponentModel.SortDescription $sd[0], $sd[1]))
    }
    switch ($script:Settings.Tab) { 'Films' { $ui.TabFilms.IsChecked = $true } 'TV' { $ui.TabTV.IsChecked = $true } }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({ try { Update-Scan } catch { Write-AppLog "Update: $($_.Exception.Message)" } })
    $window.Add_ContentRendered({
        Invoke-Safely {
            Set-Status 'Reading the last scan...'
            Read-Results
            Update-View
            $when = if (Test-Path -LiteralPath $script:ResultsPath) { "Last scan $((Get-Item -LiteralPath $script:ResultsPath).LastWriteTime.ToString('d MMM HH:mm'))." } else { 'No scan yet.' }
            Set-Status "$when Press Scan to check again."
            $timer.Start()
        }
    })
    $window.Add_Closing({ if ($script:Job) { $script:Job.Sync.Cancel = $true } })
    $window.Add_Closed({ $timer.Stop(); Save-AppSetting })
    Write-AppLog "Started v$script:AppVersion from $script:ProgramDir"
    [void]$window.ShowDialog()
} catch {
    Write-AppLog "Error: $($_.Exception.Message)"
    [void][Windows.MessageBox]::Show("$script:AppName couldn't start:`n`n$($_.Exception.Message)`n`nDetails are in $script:LogPath", $script:AppName, 'OK', 'Error')
    exit 1
}
