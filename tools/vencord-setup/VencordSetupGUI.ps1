<#
.SYNOPSIS
    VencordSetupGUI - WPF GUI installer for Vencord + community userplugins.

.DESCRIPTION
    Graphical installer (Windows Presentation Foundation) in the style of winutil.
    Startup modal Terms dialog (blurred background) blocks everything until the
    user scrolls to the end and clicks "I AGREE TO THE TERMS", then "Next".

.NOTES
    Run:  powershell -STA -ExecutionPolicy Bypass -File .\VencordSetupGUI.ps1
    Requires: Windows 10/11, PowerShell 5.1+, .NET 4.5+ (built in).
#>

# ----------------------------------------------------------------------------
# STA thread check
# ----------------------------------------------------------------------------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.UseShellExecute = $true
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    exit
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

function Get-WpfBrush([string]$hex) {
    $converter = New-Object System.Windows.Media.BrushConverter
    return $converter.ConvertFromString($hex)
}

# ----------------------------------------------------------------------------
# Settings persistence
# ----------------------------------------------------------------------------
$script:SettingsDir  = Join-Path $env:APPDATA 'VencordSetup'
$script:SettingsFile = Join-Path $script:SettingsDir 'settings.json'
$script:LogFile     = Join-Path $env:TEMP 'VencordSetup.log'

function Load-Settings {
    if (Test-Path $script:SettingsFile) {
        try {
            $raw = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            return $raw
        } catch { return $null }
    }
    return $null
}
function Save-Settings {
    if (-not (Test-Path $script:SettingsDir)) { New-Item -ItemType Directory -Path $script:SettingsDir -Force | Out-Null }
    $obj = [ordered]@{
        Path            = $txtPath.Text
        PluginQAC       = [bool]$chkQAC.IsChecked
        PluginFakeDeafen= [bool]$chkFakeDeafen.IsChecked
        PluginCloner    = [bool]$chkCloner.IsChecked
        PluginDiscordTabs = [bool]$chkDiscordTabs.IsChecked
        PluginBigFileUpload = [bool]$chkBigFileUpload.IsChecked
        SoundEnabled    = [bool]$chkSound.IsChecked
        Branch          = Get-Branch
        DryRun          = [bool]$chkDryRun.IsChecked
    }
    $obj | ConvertTo-Json | Set-Content -Path $script:SettingsFile -Encoding UTF8
}
function Update-PluginCount {
    if (-not $lblPluginCount) { return }
    $n = 0
    if ($chkQAC.IsChecked)         { $n++ }
    if ($chkFakeDeafen.IsChecked)  { $n++ }
    if ($chkCloner.IsChecked)      { $n++ }
    if ($chkDiscordTabs.IsChecked)   { $n++ }
    if ($chkBigFileUpload.IsChecked) { $n++ }
    $lblPluginCount.Text = "$n of 5 selected"
}

# ----------------------------------------------------------------------------
# Sound system (bencho.dev names -> synthesized WAV via SoundPlayer)
# ----------------------------------------------------------------------------
$script:SoundEnabled = $true
$script:SoundKeepAlive = @{}
$script:SoundTimers = @()
$script:SoundMap = @{
    'boot'     = @( @(262,120), @(392,120) )
    'click'    = @( @(880,60) )
    'success'  = @( @(523,90), @(659,90), @(784,120) )
    'error'    = @( @(330,120), @(220,160) )
    'warning'  = @( @(440,80), @(440,80) )
    'navigate' = @( @(494,70) )
    'complete' = @( @(523,100), @(659,100), @(784,100), @(1047,160) )
    'notify'   = @( @(880,60), @(1100,80) )
}

function New-ToneWavBytes([array]$tones) {
    # tones: array of @(freqHz, durationMs)
    $sampleRate = 22050
    $amplitude  = 0.25
    $gapMs      = 20
    # build PCM samples
    $samples = New-Object System.Collections.Generic.List[int]
    foreach ($t in $tones) {
        $freq = [double]$t[0]
        $dur  = [int]$t[1]
        $n    = [int]($sampleRate * $dur / 1000)
        for ($i = 0; $i -lt $n; $i++) {
            $x = $i / $sampleRate
            $val = [Math]::Sin(2 * [Math]::PI * $freq * $x) * $amplitude
            # fade in/out to avoid clicks
            $fade = [Math]::Min(1.0, [Math]::Min($i / 200.0, ($n - $i) / 200.0))
            $val = $val * $fade
            [int]$iv = [Math]::Round($val * 32767)
            if ($iv -gt 32767) { $iv = 32767 }
            if ($iv -lt -32768) { $iv = -32768 }
            $samples.Add($iv)
        }
        # gap
        $gn = [int]($sampleRate * $gapMs / 1000)
        for ($i = 0; $i -lt $gn; $i++) { $samples.Add(0) }
    }
    $numSamples = $samples.Count
    $dataSize   = $numSamples * 2
    $byteCount  = 44 + $dataSize
    $bytes = New-Object byte[] $byteCount
    # RIFF header
    $enc = [System.Text.Encoding]::ASCII
    $riff = $enc.GetBytes('RIFF'); [Array]::Copy($riff, 0, $bytes, 0, 4)
    # (header bytes set below)
    $bytes[4] = ($byteCount - 8) -band 0xFF
    $bytes[5] = (($byteCount - 8) -shr 8) -band 0xFF
    $bytes[6] = (($byteCount - 8) -shr 16) -band 0xFF
    $bytes[7] = (($byteCount - 8) -shr 24) -band 0xFF
    $wave = $enc.GetBytes('WAVE'); [Array]::Copy($wave, 0, $bytes, 8, 4)
    $fmt  = $enc.GetBytes('fmt '); [Array]::Copy($fmt, 0, $bytes, 12, 4)
    # fmt chunk size 16
    $bytes[16]=16; $bytes[17]=0; $bytes[18]=0; $bytes[19]=0
    # audio format 1 (PCM)
    $bytes[20]=1; $bytes[21]=0
    # channels 1
    $bytes[22]=1; $bytes[23]=0
    # sample rate
    $srBytes = [BitConverter]::GetBytes([uint32]$sampleRate)
    [Array]::Copy($srBytes, 0, $bytes, 24, 4)
    # byte rate = sampleRate * 1 * 16/8
    $br = $sampleRate * 2
    $brBytes = [BitConverter]::GetBytes([uint32]$br)
    [Array]::Copy($brBytes, 0, $bytes, 28, 4)
    # block align 2
    $bytes[32]=2; $bytes[33]=0
    # bits per sample 16
    $bytes[34]=16; $bytes[35]=0
    $data = $enc.GetBytes('data'); [Array]::Copy($data, 0, $bytes, 36, 4)
    $dsBytes = [BitConverter]::GetBytes([uint32]$dataSize)
    [Array]::Copy($dsBytes, 0, $bytes, 40, 4)
    # PCM data
    for ($i = 0; $i -lt $numSamples; $i++) {
        $v = $samples[$i]
        $bytes[44 + $i*2]     = $v -band 0xFF
        $bytes[44 + $i*2 + 1] = ($v -shr 8) -band 0xFF
    }
    return $bytes
}

function Play-Sound([string]$Name) {
    if (-not $script:SoundEnabled) { return }
    if (-not $script:SoundMap.ContainsKey($Name)) { $Name = 'click' }
    try {
        $wav = New-ToneWavBytes -tones $script:SoundMap[$Name]
        $ms  = New-Object System.IO.MemoryStream(,$wav)
        $sp  = New-Object System.Media.SoundPlayer($ms)
        $dur = 0
        foreach ($tone in $script:SoundMap[$Name]) { $dur += $tone[1] + 20 }
        $key = [guid]::NewGuid().ToString()
        $state = @{ Player = $sp; Stream = $ms }
        $keepAlive = $script:SoundKeepAlive
        $keepAlive[$key] = $state
        $sp.Play()
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds($dur + 100)
        $timer.Add_Tick(({
            param($sender, $e)
            $sender.Stop()
            if ($keepAlive.ContainsKey($key)) {
                $item = $keepAlive[$key]
                try { $item.Player.Stop() } catch { }
                try { $item.Stream.Dispose() } catch { }
                $keepAlive.Remove($key)
            }
        }).GetNewClosure())
        $script:SoundTimers += $timer
        $timer.Start()
    } catch {
        try {
            foreach ($tone in $script:SoundMap[$Name]) { [Console]::Beep($tone[0], $tone[1]) }
        } catch { }
    }
}

# ----------------------------------------------------------------------------
# XAML
# ----------------------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VencordSetup" Height="720" Width="1000"
        WindowStartupLocation="CenterScreen" Background="#1e1e2e" Foreground="#cdd6f4"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        ResizeMode="NoResize" WindowStyle="SingleBorderWindow">
  <Window.Resources>
    <Style x:Key="FocusVisual">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Rectangle Margin="2" Stroke="#f9e2af" StrokeThickness="2" StrokeDashArray="1 2" SnapsToDevicePixels="True"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusVisual}"/>
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="Foreground" Value="#cdd6f4"/>
      <Setter Property="BorderBrush" Value="#45475a"/>
      <Setter Property="BorderThickness" Value="0,0,0,2"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="4,0"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8,8,0,0" Padding="{TemplateBinding Padding}"
                    Margin="{TemplateBinding Margin}" SnapsToDevicePixels="True">
              <ContentPresenter x:Name="Cp" ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#45475a"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#89b4fa"/>
                <Setter Property="Foreground" Value="#1e1e2e"/>
                <Setter TargetName="Cp" Property="TextElement.Foreground" Value="#1e1e2e"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#89b4fa"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SegmentedRadio" TargetType="RadioButton">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusVisual}"/>
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="Foreground" Value="#cdd6f4"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#89b4fa"/>
                <Setter Property="Foreground" Value="#1e1e2e"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#45475a"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Rounded button style -->
    <Style TargetType="Button">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusVisual}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- ProgressBar: keep default template (reliable), round via outer border in XAML -->
    <!-- Rounded textbox -->
    <Style TargetType="TextBox">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusVisual}"/>
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="Foreground" Value="#cdd6f4"/>
      <Setter Property="BorderBrush" Value="#45475a"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Focusable="false"
                            Padding="{TemplateBinding Padding}"
                            HorizontalScrollBarVisibility="{TemplateBinding ScrollViewer.HorizontalScrollBarVisibility}"
                            VerticalScrollBarVisibility="{TemplateBinding ScrollViewer.VerticalScrollBarVisibility}"
                            HorizontalContentAlignment="{TemplateBinding HorizontalContentAlignment}"
                            VerticalContentAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Toggle switch for plugin cards -->
    <Style x:Key="ToggleSwitch" TargetType="CheckBox">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusVisual}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="46" Height="26">
              <Border x:Name="Track" Width="46" Height="26" CornerRadius="13" Background="#45475a" BorderBrush="#585b70" BorderThickness="1"/>
              <Border x:Name="Thumb" Width="18" Height="18" CornerRadius="9" Background="#cdd6f4"
                      HorizontalAlignment="Left" VerticalAlignment="Center" Margin="4,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#a6e3a1"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="#a6e3a1"/>
                <Setter TargetName="Thumb" Property="Background" Value="#1e1e2e"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Thumb" Property="Margin" Value="0,0,4,0"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Track" Property="Opacity" Value="0.82"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Interactive plugin card -->
    <Style x:Key="PluginCard" TargetType="Border">
      <Setter Property="Background" Value="#252736"/>
      <Setter Property="BorderBrush" Value="#45475a"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="14"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#2c2f42"/>
          <Setter Property="BorderBrush" Value="#6c7086"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid x:Name="RootGrid">
    <Grid.RowDefinitions>
      <RowDefinition Height="64"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="36"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#181825" Padding="18,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Path Data="M12 15C13.6569 15 15 13.6569 15 12C15 10.3431 13.6569 9 12 9C10.3431 9 9 10.3431 9 12C9 13.6569 10.3431 15 12 15Z M19.6224 10.3954L18.5247 7.7448L20 6L18 4L16.2647 5.48295L13.5578 4.36974L12.9353 2H10.981L10.3491 4.40113L7.70441 5.51596L6 4L4 6L5.45337 7.78885L4.3725 10.4463L2 11V13L4.40111 13.6555L5.51575 16.2997L4 18L6 20L7.79116 18.5403L10.397 19.6123L11 22H13L13.6045 19.6132L16.2551 18.5155C16.6969 18.8313 18 20 18 20L20 18L18.5159 16.2494L19.6139 13.598L21.9999 12.9772L22 11L19.6224 10.3954Z" Stroke="#89b4fa" StrokeThickness="1.5" Fill="Transparent" Stretch="Uniform" Width="28" Height="28" Margin="0,0,12,0" VerticalAlignment="Center"/>
          <TextBlock Text="VencordSetup" FontSize="20" FontWeight="Bold" Foreground="#cdd6f4" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock Grid.Column="1" Text="Vencord + custom plugins installer" FontSize="12" Foreground="#a6adc8"
                   VerticalAlignment="Center" HorizontalAlignment="Right" Margin="0,0,4,0"/>
      </Grid>
    </Border>

    <!-- Tabs -->
    <TabControl x:Name="Tabs" Grid.Row="1" Background="#1e1e2e" BorderBrush="#313244" Foreground="#cdd6f4"
                IsEnabled="False" Margin="12,10,12,6" Padding="0">
      <TabControl.ItemsPanel>
        <ItemsPanelTemplate>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center"/>
        </ItemsPanelTemplate>
      </TabControl.ItemsPanel>

      <!-- Welcome -->
      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <Path Data="M2 8L11.7317 3.13416C11.9006 3.04971 12.0994 3.0497 12.2683 3.13416L22 8 M20 11V19C20 20.1046 19.1046 21 18 21H6C4.89543 21 4 20.1046 4 19V11" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType={x:Type TabItem}}}" StrokeThickness="1.5" Fill="Transparent" Stretch="Uniform" Width="16" Height="16" Margin="0,0,6,0" VerticalAlignment="Center"/>
            <TextBlock Text="Welcome"/>
          </StackPanel>
        </TabItem.Header>
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="20">
          <StackPanel MaxWidth="760" HorizontalAlignment="Center">
            <TextBlock Text="Welcome" FontSize="24" FontWeight="Bold" Foreground="#89b4fa" Margin="0,0,0,10" HorizontalAlignment="Center"/>
            <TextBlock TextWrapping="Wrap" Foreground="#cdd6f4" Margin="0,0,0,14" TextAlignment="Center"
              Text="This tool sets up Vencord with community userplugins (Quest-Auto-Complete, Discord-Fake-Deafen, Discord-Server-Cloner, DiscordTabs, bigFileUpload). It clones, builds and injects into Discord Stable."/>
            <Border Background="#313244" CornerRadius="10" Padding="16" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="WARNING" FontWeight="Bold" Foreground="#f38ba8" Margin="0,0,0,6"/>
                <TextBlock TextWrapping="Wrap" Foreground="#cdd6f4"
                  Text="Client mods violate Discord's Terms of Service. Account enforcement can include bans. Your account is at risk. If your account is critical, do not proceed. Review plugin source yourself."/>
              </StackPanel>
            </Border>
            <Border Background="#252736" CornerRadius="10" Padding="16" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="UPDATE LOG" FontWeight="Bold" Foreground="#a6e3a1" Margin="0,0,0,8"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,10"
                  Text="each version has a full note in the UPDATES folder of the repo"/>
                <TextBlock Text="v2.1 - 2026-11-24" FontWeight="SemiBold" Foreground="#89b4fa" Margin="0,0,0,2"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,8"
                  Text="fixed the pnpm working directory so build runs in the cloned folder; stops early if the clone layout is wrong"/>
                <TextBlock Text="v2.0 - 2026-11-22" FontWeight="SemiBold" Foreground="#89b4fa" Margin="0,0,0,2"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,8"
                  Text="hardened inject with trusted CLI exit codes, responsive progress, selection-aware updates, accurate terms, and a self-contained one-line installer"/>
                <TextBlock Text="v1.9 - 2026-11-22" FontWeight="SemiBold" Foreground="#89b4fa" Margin="0,0,0,2"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,8"
                  Text="fixed false not-found-in-bundle warnings for plugins with declared names that differ from folder names"/>
                <TextBlock Text="v1.8 - 2026-11-22" FontWeight="SemiBold" Foreground="#89b4fa" Margin="0,0,0,2"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,8"
                  Text="removed the OK popup after install and update; status and log still report completion"/>
                <TextBlock Text="v1.7 - 2026-11-22" FontWeight="SemiBold" Foreground="#89b4fa" Margin="0,0,0,2"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,8"
                  Text="enlarged the Clear log button so its label is fully visible"/>
                <TextBlock Text="v1.6 - 2026-11-22" FontWeight="SemiBold" Foreground="#89b4fa" Margin="0,0,0,2"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,8"
                  Text="added a Clear log button to the install log panel"/>
                <TextBlock Text="v1.5 - 2026-11-22" FontWeight="SemiBold" Foreground="#89b4fa" Margin="0,0,0,2"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,8"
                  Text="fixed false pnpm-missing message and real pnpm install in prerequisite helper"/>
                <TextBlock Text="v1.4 - 2026-11-22" FontWeight="SemiBold" Foreground="#89b4fa" Margin="0,0,0,2"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,8"
                  Text="fixed plugin build on current Vencord, self-healing compat patch, step logs"/>
                <TextBlock Text="v1.3 - 2026-11-22" FontWeight="SemiBold" Foreground="#89b4fa" Margin="0,0,0,2"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,8"
                  Text="added DiscordTabs as a fifth plugin, with token-use disclosure"/>
                <TextBlock Text="v1.2 - 2026-11-22" FontWeight="SemiBold" Foreground="#89b4fa" Margin="0,0,0,2"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,8"
                  Text="setup-only terms, accurate upstream credits and licenses, this update log"/>
                <TextBlock Text="v1.1 - 2026-11-22" FontWeight="SemiBold" Foreground="#89b4fa" Margin="0,0,0,2"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,8"
                  Text="standalone terms and policies; prompt dump files removed, terms and decision dialogs kept"/>
                <TextBlock Text="v1.0 - 2026-11-22" FontWeight="SemiBold" Foreground="#89b4fa" Margin="0,0,0,2"/>
                <TextBlock TextWrapping="Wrap" Foreground="#a6adc8"
                  Text="wpf installer, four plugin cards, repair, update, re-inject, uninstall, log export"/>
              </StackPanel>
            </Border>
            <TextBlock Text="You accepted the full terms in the startup dialog." Foreground="#a6adc8" FontStyle="Italic" HorizontalAlignment="Center"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- Prerequisites -->
      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <Path Data="M5 18L3.13036 4.91253C3.05646 4.39524 3.39389 3.91247 3.90398 3.79912L11.5661 2.09641C11.8519 2.03291 12.1481 2.03291 12.4339 2.09641L20.096 3.79912C20.6061 3.91247 20.9435 4.39524 20.8696 4.91252L19 18C18.9293 18.495 18.5 21.5 12 21.5C5.5 21.5 5.07071 18.495 5 18Z" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType={x:Type TabItem}}}" StrokeThickness="1.5" Fill="Transparent" Stretch="Uniform" Width="16" Height="16" Margin="0,0,6,0" VerticalAlignment="Center"/>
            <TextBlock Text="Prereqs"/>
          </StackPanel>
        </TabItem.Header>
        <StackPanel Margin="24">
          <TextBlock Text="Prerequisites" FontSize="24" FontWeight="Bold" Foreground="#89b4fa" Margin="0,0,0,8"/>
          <TextBlock TextWrapping="Wrap" Foreground="#cdd6f4" Margin="0,0,0,14" Text="All three must be installed. Click 'Re-check' after installing."/>
          <Border Background="#313244" CornerRadius="10" Padding="16" Margin="0,0,0,14">
            <StackPanel>
              <TextBlock x:Name="LblNode" Foreground="#cdd6f4" Margin="0,2" FontSize="13"/>
              <TextBlock x:Name="LblGit" Foreground="#cdd6f4" Margin="0,2" FontSize="13"/>
              <TextBlock x:Name="LblPnpm" Foreground="#cdd6f4" Margin="0,2" FontSize="13"/>
            </StackPanel>
          </Border>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
            <Button x:Name="BtnRecheck" Content="Re-check" Width="110" Height="32" Background="#89b4fa" Foreground="#1e1e2e" FontWeight="Bold" Margin="0,0,8,0"/>
            <Button x:Name="BtnWinget" Content="Install missing (winget)" Width="190" Height="32" Background="#fab387" Foreground="#1e1e2e" FontWeight="Bold" Margin="0,0,8,0"/>
            <TextBlock VerticalAlignment="Center" Foreground="#a6adc8" FontSize="11" Text="Node: nodejs.org  |  Git: git-scm.com  |  pnpm: npm install -g pnpm"/>
          </StackPanel>
          <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" FontSize="11" Text="Download links: https://nodejs.org/en  |  https://git-scm.com  |  then run: npm install -g pnpm"/>
        </StackPanel>
      </TabItem>

      <!-- Location -->
      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <Path Data="M2 11V4.6C2 4.26863 2.26863 4 2.6 4H8.77805C8.92127 4 9.05977 4.05124 9.16852 4.14445L12.3315 6.85555C12.4402 6.94876 12.5787 7 12.722 7H21.4C21.7314 7 22 7.26863 22 7.6V11M2 11V19.4C2 19.7314 2.26863 20 2.6 20H21.4C21.7314 20 22 19.7314 22 19.4V11M2 11H22" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType={x:Type TabItem}}}" StrokeThickness="1.5" Fill="Transparent" Stretch="Uniform" Width="16" Height="16" Margin="0,0,6,0" VerticalAlignment="Center"/>
            <TextBlock Text="Location"/>
          </StackPanel>
        </TabItem.Header>
        <Grid Margin="24">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="Install location" FontSize="24" FontWeight="Bold" Foreground="#89b4fa" Margin="0,0,0,8"/>
          <TextBlock Grid.Row="1" TextWrapping="Wrap" Foreground="#cdd6f4" Margin="0,0,0,14"
            Text="Choose the parent folder. A 'Vencord' subfolder will be created there."/>
          <StackPanel Grid.Row="2" Margin="0,0,0,10">
            <Button x:Name="BtnBrowse" Content="Browse..." Width="120" Height="34"
                    HorizontalAlignment="Left" Margin="0,0,0,8"
                    Background="#89b4fa" Foreground="#1e1e2e" FontWeight="Bold"/>
            <TextBox x:Name="TxtPath" Height="40" Background="#313244" Foreground="#cdd6f4"
                     BorderBrush="#45475a" Padding="10,8" VerticalContentAlignment="Center" FontSize="13"/>
          </StackPanel>
          <TextBlock x:Name="LblPathStatus" Grid.Row="3" Foreground="#a6adc8" Text="" VerticalAlignment="Top" TextWrapping="Wrap"/>
          <StackPanel Grid.Row="4" Orientation="Horizontal" Margin="0,8,0,0">
            <TextBlock Text="Discord branch:" Foreground="#cdd6f4" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <Border Background="#313244" CornerRadius="8" Padding="2" BorderBrush="#45475a" BorderThickness="1">
              <StackPanel x:Name="BranchPanel" Orientation="Horizontal">
                <RadioButton x:Name="RbAuto" Content="auto" GroupName="Branch" IsChecked="True" Style="{StaticResource SegmentedRadio}"/>
                <RadioButton x:Name="RbStable" Content="stable" GroupName="Branch" Style="{StaticResource SegmentedRadio}"/>
                <RadioButton x:Name="RbPtb" Content="ptb" GroupName="Branch" Style="{StaticResource SegmentedRadio}"/>
                <RadioButton x:Name="RbCanary" Content="canary" GroupName="Branch" Style="{StaticResource SegmentedRadio}"/>
              </StackPanel>
            </Border>
            <TextBlock Text="  (auto = installer detects)" Foreground="#a6adc8" FontSize="11" VerticalAlignment="Center" Margin="8,0,0,0"/>
          </StackPanel>
          <TextBlock x:Name="LblUpdateStatus" Grid.Row="5" Foreground="#a6adc8" Text="" VerticalAlignment="Top" Margin="0,6,0,0" TextWrapping="Wrap"/>
        </Grid>
      </TabItem>

      <!-- Plugins -->
      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <Path Data="M4 14V18.4C4 18.7314 4.26863 19 4.6 19H10 M19 14V18.4C19 18.7314 18.7314 19 18.4 19H14 M14 5H18.4C18.7314 5 19 5.26863 19 5.6V10 M4 10V5.6C4 5.26863 4.26863 5 4.6 5H10 M14 19V20C14 21.1046 13.1046 22 12 22C10.8954 22 10 21.1046 10 20V19 M4 10H5C6.10457 10 7 10.8954 7 12C7 13.1046 6.10457 14 5 14H4 M19 10H20C21.1046 10 22 10.8954 22 12C22 13.1046 21.1046 14 20 14H19 M14 5V4C14 2.89543 13.1046 2 12 2C10.8954 2 10 2.89543 10 4V5" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType={x:Type TabItem}}}" StrokeThickness="1.5" Fill="Transparent" Stretch="Uniform" Width="16" Height="16" Margin="0,0,6,0" VerticalAlignment="Center"/>
            <TextBlock Text="Plugins"/>
          </StackPanel>
        </TabItem.Header>
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24">
            <TextBlock Text="Plugins to install" FontSize="24" FontWeight="Bold" Foreground="#89b4fa" Margin="0,0,0,6"/>
            <TextBlock TextWrapping="Wrap" Foreground="#a6adc8" Margin="0,0,0,14" FontSize="13"
                       Text="Pick the BlockTol plugins to clone and build. Switch them on or off anytime."/>

            <Grid Margin="0,0,0,12">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <Border Background="#313244" CornerRadius="10" Padding="10,5" BorderBrush="#45475a" BorderThickness="1">
                  <TextBlock x:Name="LblPluginCount" Text="5 of 5 selected" Foreground="#a6e3a1" FontWeight="Bold" FontSize="12"/>
                </Border>
              </StackPanel>
              <Button x:Name="BtnClearAll" Grid.Column="1" Content="Clear all" Width="96" Height="32" Margin="0,0,8,0"
                      Background="#313244" BorderBrush="#585b70" BorderThickness="1" Foreground="#cdd6f4" FontWeight="Bold"/>
              <Button x:Name="BtnSelectAll" Grid.Column="2" Content="Select all" Width="96" Height="32"
                      Background="#313244" BorderBrush="#a6e3a1" BorderThickness="1" Foreground="#a6e3a1" FontWeight="Bold"/>
            </Grid>

            <Border Style="{StaticResource PluginCard}" Margin="0,0,0,10" ToolTip="Automatically completes quests and tracks progress.">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Border Width="44" Height="44" CornerRadius="11" Background="#313244" BorderBrush="#a6e3a1" BorderThickness="1" VerticalAlignment="Center">
                  <Path Data="M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18 M8 12l3 3 5-6" Width="22" Height="22" Stretch="Uniform"
                        Stroke="#a6e3a1" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="14,0,14,0" VerticalAlignment="Center">
                  <TextBlock Text="Quest-Auto-Complete" Foreground="#cdd6f4" FontWeight="Bold" FontSize="14"/>
                  <TextBlock Text="Auto-completes quests and tracks progress." Foreground="#a6adc8" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,3"/>
                  <TextBlock Text="BlockTol / Quest-Auto-Complete" Foreground="#a6adc8" FontSize="11" FontFamily="Consolas"/>
                </StackPanel>
                <CheckBox x:Name="ChkQAC" Grid.Column="2" IsChecked="True" Style="{StaticResource ToggleSwitch}" VerticalAlignment="Center" ToolTip="Enable Quest-Auto-Complete"/>
              </Grid>
            </Border>

            <Border Style="{StaticResource PluginCard}" Margin="0,0,0,10" ToolTip="Shows a deafen state without muting your audio.">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Border Width="44" Height="44" CornerRadius="11" Background="#313244" BorderBrush="#cba6f7" BorderThickness="1" VerticalAlignment="Center">
                  <Path Data="M4 9v6h4l5 4V5L8 9H4 M17 9l4 6 M21 9l-4 6" Width="22" Height="22" Stretch="Uniform"
                        Stroke="#cba6f7" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="14,0,14,0" VerticalAlignment="Center">
                  <TextBlock Text="Discord-Fake-Deafen" Foreground="#cdd6f4" FontWeight="Bold" FontSize="14"/>
                  <TextBlock Text="Shows a deafen state without muting your audio." Foreground="#a6adc8" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,3"/>
                  <TextBlock Text="BlockTol / Discord-Fake-Deafen" Foreground="#a6adc8" FontSize="11" FontFamily="Consolas"/>
                </StackPanel>
                <CheckBox x:Name="ChkFakeDeafen" Grid.Column="2" IsChecked="True" Style="{StaticResource ToggleSwitch}" VerticalAlignment="Center" ToolTip="Enable Discord-Fake-Deafen"/>
              </Grid>
            </Border>

            <Border Style="{StaticResource PluginCard}" Margin="0,0,0,10" ToolTip="Copies server roles, channels and settings.">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Border Width="44" Height="44" CornerRadius="11" Background="#313244" BorderBrush="#89b4fa" BorderThickness="1" VerticalAlignment="Center">
                  <Path Data="M9 8h11v11H9z M5 16V5h11" Width="22" Height="22" Stretch="Uniform"
                        Stroke="#89b4fa" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="14,0,14,0" VerticalAlignment="Center">
                  <TextBlock Text="Discord-Server-Cloner" Foreground="#cdd6f4" FontWeight="Bold" FontSize="14"/>
                  <TextBlock Text="Copies server roles, channels and settings." Foreground="#a6adc8" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,3"/>
                  <TextBlock Text="BlockTol / Discord-Server-Cloner" Foreground="#a6adc8" FontSize="11" FontFamily="Consolas"/>
                </StackPanel>
                <CheckBox x:Name="ChkCloner" Grid.Column="2" IsChecked="True" Style="{StaticResource ToggleSwitch}" VerticalAlignment="Center" ToolTip="Enable Discord-Server-Cloner"/>
              </Grid>
            </Border>

            <Border Style="{StaticResource PluginCard}" Margin="0,0,0,10" ToolTip="Run several Discord accounts as tabs in one window.">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Border Width="44" Height="44" CornerRadius="11" Background="#313244" BorderBrush="#f38ba8" BorderThickness="1" VerticalAlignment="Center">
                  <Path Data="M4 7h16v12H4z M4 11h16 M8 7V5h8v2" Width="22" Height="22" Stretch="Uniform"
                        Stroke="#f38ba8" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="14,0,14,0" VerticalAlignment="Center">
                  <TextBlock Text="DiscordTabs" Foreground="#cdd6f4" FontWeight="Bold" FontSize="14"/>
                  <TextBlock Text="Multiple Discord accounts as tabs in one window." Foreground="#a6adc8" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,3"/>
                  <TextBlock Text="BlockTol / DiscordTabs" Foreground="#a6adc8" FontSize="11" FontFamily="Consolas"/>
                </StackPanel>
                <CheckBox x:Name="ChkDiscordTabs" Grid.Column="2" IsChecked="True" Style="{StaticResource ToggleSwitch}" VerticalAlignment="Center" ToolTip="Enable DiscordTabs"/>
              </Grid>
            </Border>

            <Border Style="{StaticResource PluginCard}" Margin="0,0,0,14" ToolTip="Sends over-limit files to external hosts and pastes the link.">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Border Width="44" Height="44" CornerRadius="11" Background="#313244" BorderBrush="#f9e2af" BorderThickness="1" VerticalAlignment="Center">
                  <Path Data="M12 16V4 M12 4l-4 4 M12 4l4 4 M4 16v2.4C4 19.7314 4.26863 20 4.6 20H19.4C19.7314 20 20 19.7314 20 19.4V16" Width="22" Height="22" Stretch="Uniform"
                        Stroke="#f9e2af" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="14,0,14,0" VerticalAlignment="Center">
                  <TextBlock Text="bigFileUpload" Foreground="#cdd6f4" FontWeight="Bold" FontSize="14"/>
                  <TextBlock Text="Bypasses Discord's upload limit via external hosts." Foreground="#a6adc8" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,3"/>
                  <TextBlock Text="ScattrdBlade / bigFileUpload" Foreground="#a6adc8" FontSize="11" FontFamily="Consolas"/>
                </StackPanel>
                <CheckBox x:Name="ChkBigFileUpload" Grid.Column="2" IsChecked="True" Style="{StaticResource ToggleSwitch}" VerticalAlignment="Center" ToolTip="Enable bigFileUpload"/>
              </Grid>
            </Border>

            <Border Background="#252736" BorderBrush="#45475a" BorderThickness="1" CornerRadius="12" Padding="14">
              <StackPanel>
                <TextBlock Text="Options" Foreground="#89b4fa" FontWeight="Bold" FontSize="13" Margin="0,0,0,8"/>
                <CheckBox x:Name="ChkSound" Content="Enable sound feedback" IsChecked="True" Foreground="#cdd6f4" FontSize="13"/>
                <CheckBox x:Name="ChkDryRun" Content="Dry-run (simulate, no changes)" IsChecked="False" Foreground="#cdd6f4" FontSize="13" Margin="0,6,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- Install -->
      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <Path Data="M6 20L18 20 M12 4V16M12 16L15.5 12.5M12 16L8.5 12.5" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType={x:Type TabItem}}}" StrokeThickness="1.5" Fill="Transparent" Stretch="Uniform" Width="16" Height="16" Margin="0,0,6,0" VerticalAlignment="Center"/>
            <TextBlock Text="Install"/>
          </StackPanel>
        </TabItem.Header>
        <Grid Margin="24">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="Install" FontSize="24" FontWeight="Bold" Foreground="#89b4fa" Margin="0,0,0,10"/>
          <ProgressBar x:Name="Pb" Grid.Row="1" Height="20" Margin="0,0,0,10" Background="#313244" Foreground="#a6e3a1" BorderBrush="#45475a"/>
          <TextBlock x:Name="LblStatus" Grid.Row="2" Foreground="#cdd6f4" Text="Ready." Margin="0,0,0,10" FontSize="13" TextWrapping="Wrap"/>
          <WrapPanel Grid.Row="3" Margin="0,0,0,10">
            <Button x:Name="BtnInstall" Width="150" Height="36" Background="#313244" BorderBrush="#a6e3a1" BorderThickness="1" Foreground="#a6e3a1" FontWeight="Bold" FontSize="13" Margin="0,0,8,4">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Center">
                <Path Data="M12 3v12 M7 10l5 5 5-5 M4 17v3h16v-3" Width="16" Height="16" Stretch="Uniform" Stroke="#a6e3a1" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent" Margin="0,0,7,0"/>
                <TextBlock Text="Start install" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnRepair" Width="145" Height="36" Background="#313244" BorderBrush="#fab387" BorderThickness="1" Foreground="#fab387" FontWeight="Bold" FontSize="13" Margin="0,0,8,4">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Center">
                <Path Data="M14.5 5.5a4 4 0 0 0-5 5L4 16l4 4 5.5-5.5a4 4 0 0 0 5-5l-3 3-3-3 2-2z" Width="16" Height="16" Stretch="Uniform" Stroke="#fab387" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent" Margin="0,0,7,0"/>
                <TextBlock Text="Repair core" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnUpdate" Width="125" Height="36" Background="#313244" BorderBrush="#89b4fa" BorderThickness="1" Foreground="#89b4fa" FontWeight="Bold" FontSize="13" Margin="0,0,8,4">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Center">
                <Path Data="M19 8a8 8 0 0 0-14-2L3 8 M3 4v4h4 M5 16a8 8 0 0 0 14 2l2-2 M21 20v-4h-4" Width="16" Height="16" Stretch="Uniform" Stroke="#89b4fa" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent" Margin="0,0,7,0"/>
                <TextBlock Text="Update" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnReinject" Width="180" Height="36" Background="#313244" BorderBrush="#cba6f7" BorderThickness="1" Foreground="#cba6f7" FontWeight="Bold" FontSize="13" Margin="0,0,8,4">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Center">
                <Path Data="M9 3v6 M15 3v6 M7 9h10v3a5 5 0 0 1-10 0V9 M12 17v4" Width="16" Height="16" Stretch="Uniform" Stroke="#cba6f7" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent" Margin="0,0,7,0"/>
                <TextBlock Text="Re-inject plugins" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
          </WrapPanel>
          <TextBlock Grid.Row="4" Text="Log:" Foreground="#a6adc8" Margin="0,6,0,4" FontSize="12" VerticalAlignment="Center"/>
          <Button x:Name="BtnClearLog" Grid.Row="4" Width="112" Height="30" HorizontalAlignment="Right" Margin="0,2,0,2" Padding="8,2"
                  Background="#313244" BorderBrush="#585b70" BorderThickness="1" Foreground="#cdd6f4" FontWeight="Bold" FontSize="12"
                  ToolTip="Clear the log display">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Center">
              <Path Data="M4 7h16 M9 7V4h6v3 M6 7l1 14h10l1-14 M10 11v6 M14 11v6" Width="15" Height="15" Stretch="Uniform" Stroke="#cdd6f4" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent" Margin="0,0,7,0"/>
              <TextBlock Text="Clear log" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <TextBox x:Name="TxtLog" Grid.Row="5" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                   Background="#11111b" Foreground="#cdd6f4" BorderBrush="#313244" FontFamily="Consolas" FontSize="11"
                   Padding="8"/>
          <Grid Grid.Row="6" Margin="0,6,0,0">
            <Button x:Name="BtnUninstall" Width="145" Height="30" HorizontalAlignment="Left"
                    Background="#f38ba8" BorderBrush="#f38ba8" BorderThickness="1" Foreground="#1e1e2e" FontWeight="Bold">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Center">
                <Path Data="M4 7h16 M9 7V4h6v3 M6 7l1 14h10l1-14 M10 11v6 M14 11v6" Width="15" Height="15" Stretch="Uniform" Stroke="#1e1e2e" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent" Margin="0,0,7,0"/>
                <TextBlock Text="Uninstall all" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnExportLog" Width="135" Height="30" HorizontalAlignment="Right"
                    Background="#6c7086" Foreground="#cdd6f4" FontWeight="Bold">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Center">
                <Path Data="M5 3h11l3 3v15H5z M8 3v6h8V3 M8 14h8v6H8z" Width="15" Height="15" Stretch="Uniform" Stroke="#cdd6f4" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent" Margin="0,0,7,0"/>
                <TextBlock Text="Export log" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
          </Grid>
        </Grid>
      </TabItem>
    </TabControl>

    <!-- Footer -->
    <Border Grid.Row="2" Background="#181825" Padding="18,0">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Path Data="M12 11.5V16.5 M12 7.51L12.01 7.49889 M12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22Z" Stroke="#6c7086" StrokeThickness="1.5" Fill="Transparent" Stretch="Uniform" Width="14" Height="14" Margin="0,0,8,0" VerticalAlignment="Center"/>
        <TextBlock Text="made by: ! ayeti | @xiari.i" FontSize="11" Foreground="#a6adc8"/>
      </StackPanel>
    </Border>

    <!-- Terms overlay -->
    <Grid x:Name="Overlay" Grid.Row="0" Grid.RowSpan="3" Background="#CC000000" Panel.ZIndex="1000">
      <Border Background="#1e1e2e" BorderBrush="#89b4fa" BorderThickness="1" CornerRadius="14"
              Width="780" Height="580" HorizontalAlignment="Center" VerticalAlignment="Center" Padding="22">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <Path Data="M5 18L3.13036 4.91253C3.05646 4.39524 3.39389 3.91247 3.90398 3.79912L11.5661 2.09641C11.8519 2.03291 12.1481 2.03291 12.4339 2.09641L20.096 3.79912C20.6061 3.91247 20.9435 4.39524 20.8696 4.91252L19 18C18.9293 18.495 18.5 21.5 12 21.5C5.5 21.5 5.07071 18.495 5 18Z" Stroke="#89b4fa" StrokeThickness="1.5" Fill="Transparent" Stretch="Uniform" Width="20" Height="20" Margin="0,0,8,0" VerticalAlignment="Center"/>
            <TextBlock Text="Terms &amp; Conditions - read to the end" FontSize="18" FontWeight="Bold" Foreground="#89b4fa"/>
          </StackPanel>
          <ScrollViewer x:Name="TermsScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" Background="#181825" Padding="14" BorderBrush="#313244" BorderThickness="1">
            <TextBlock x:Name="TermsText" TextWrapping="Wrap" Foreground="#cdd6f4" FontSize="12" LineHeight="18"/>
          </ScrollViewer>
          <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="BtnDecline" Content="Decline" Width="90" Height="34" Margin="0,0,8,0" IsCancel="True" Background="#f38ba8" Foreground="#1e1e2e" FontWeight="Bold"/>
            <Button x:Name="BtnAgree" Content="I AGREE TO THE TERMS" Width="210" Height="34" IsEnabled="False" Background="#a6e3a1" Foreground="#1e1e2e" FontWeight="Bold"/>
            <Button x:Name="BtnNext" Content="Next" Width="90" Height="34" Margin="8,0,0,0" Visibility="Collapsed" IsDefault="True" Background="#89b4fa" Foreground="#1e1e2e" FontWeight="Bold"/>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# ----------------------------------------------------------------------------
# Control references
# ----------------------------------------------------------------------------
$tabs          = $window.FindName('Tabs')
$txtPath       = $window.FindName('TxtPath')
$btnBrowse     = $window.FindName('BtnBrowse')
$lblPathStatus = $window.FindName('LblPathStatus')
$lblUpdateStatus = $window.FindName('LblUpdateStatus')
$rbAuto = $window.FindName('RbAuto')
$rbStable = $window.FindName('RbStable')
$rbPtb = $window.FindName('RbPtb')
$rbCanary = $window.FindName('RbCanary')
$chkQAC        = $window.FindName('ChkQAC')
$chkFakeDeafen = $window.FindName('ChkFakeDeafen')
$chkCloner     = $window.FindName('ChkCloner')
$chkDiscordTabs   = $window.FindName('ChkDiscordTabs')
$chkBigFileUpload = $window.FindName('ChkBigFileUpload')
$chkSound      = $window.FindName('ChkSound')
$chkDryRun     = $window.FindName('ChkDryRun')
$lblPluginCount= $window.FindName('LblPluginCount')
$btnSelectAll  = $window.FindName('BtnSelectAll')
$btnClearAll   = $window.FindName('BtnClearAll')
$btnExportLog  = $window.FindName('BtnExportLog')
$btnClearLog   = $window.FindName('BtnClearLog')
$pb            = $window.FindName('Pb')
$lblStatus     = $window.FindName('LblStatus')
$btnInstall    = $window.FindName('BtnInstall')
# BtnCancel removed
$btnRepair     = $window.FindName('BtnRepair')
$btnUninstall  = $window.FindName('BtnUninstall')
$btnUpdate     = $window.FindName('BtnUpdate')
$btnReinject   = $window.FindName('BtnReinject')
$txtLog        = $window.FindName('TxtLog')
$overlay       = $window.FindName('Overlay')
$termsScroll   = $window.FindName('TermsScroll')
$termsText     = $window.FindName('TermsText')
$btnAgree      = $window.FindName('BtnAgree')
$btnDecline    = $window.FindName('BtnDecline')
$btnNext       = $window.FindName('BtnNext')
$lblNode       = $window.FindName('LblNode')
$lblGit        = $window.FindName('LblGit')
$lblPnpm       = $window.FindName('LblPnpm')
$btnRecheck    = $window.FindName('BtnRecheck')
$btnWinget     = $window.FindName('BtnWinget')

# ----------------------------------------------------------------------------
# Terms text
# ----------------------------------------------------------------------------
$termsFull = @"
VENCORDSETUP - TERMS, PRIVACY & COOKIE POLICY
=============================================
LAST UPDATED: 2026-11-22

NOTE: These terms are provided as a template for protection. They are NOT
legal advice. Consult a qualified attorney for enforceability in your
jurisdiction. No terms can guarantee immunity from lawsuits.

=============================================

READ THIS ENTIRE DOCUMENT. The "I AGREE TO THE TERMS" button stays disabled
until you scroll to the bottom.

1. WHAT THIS TOOL DOES
   - Checks Node.js 22+, Git and pnpm are installed.
   - git clone https://github.com/Vendicated/Vencord into your chosen folder.
   - git clone https://github.com/BlockTol/Quest-Auto-Complete
   - git clone https://github.com/BlockTol/Discord-Fake-Deafen
   - git clone https://github.com/BlockTol/Discord-Server-Cloner
   - git clone https://github.com/BlockTol/DiscordTabs
   - git clone https://github.com/ScattrdBlade/bigFileUpload
   - pnpm install (downloads JavaScript packages from npm registry).
   - pnpm build (compiles the Vencord bundle).
    - node scripts/runInstaller.mjs fetches the official
      VencordInstallerCli.exe from Vencord/Installer releases. It is not
      compiled locally. The check runs on every inject so updates arrive.
    - that CLI runs with -branch <chosen> -install (or -uninstall) and
      patches Discord locally. Branch choices: auto, stable, ptb, canary.
    - if launched from the one-line command, install.ps1 and its .sha256
      file are downloaded from raw.githubusercontent.com first. The hash is
      verified before the local file runs. The GUI is bundled inside it.
    No services, scheduled tasks, or persistent background agents are
    installed. Beeps are short-lived. A one-shot git fetch update check
    runs on launch when a saved target folder exists. No registry changes
    beyond what Discord, pnpm, or optional winget installs do themselves.

    This tool is an installer and convenience layer only. It does not contain
    Discord source, Vencord source, or plugin source. Those projects are
    downloaded from their own repositories at run time and are written and
    maintained by their own authors. We only automate cloning, building and
    injecting. We do not write, patch or control the client modification.
    Calling this a "setup tool" describes what we ship. It does not make the
    modified client compliant with Discord's Terms of Service.

2. WARNING - ACCOUNT RISK
   Client modifications violate Discord's Terms of Service. Enforcement can
   include account bans. Your account is at risk. If your account is
   critical to you, do NOT proceed. You accept all risk.
   Stating that this repo is only a setup tool does not change Discord's rules.
   Discord applies its Terms to the client you run, not to who wrote the
   installer. This disclaimer limits OUR liability. It does not grant
   permission from Discord or prevent enforcement by Discord.

3. THIRD-PARTY CODE
   Plugins are authored by others (BlockTol, ScattrdBlade). Review their
   source before enabling. We are not responsible for plugin behavior.
   DiscordTabs reads account tokens from Discord's own local store to log a
   new tab in. The token is passed inside Discord and is not written to a
   file or sent to a server by that plugin. Enable it only if you accept
   that access.
   bigFileUpload sends files you choose to external hosting providers.

4. NO REDISTRIBUTION of patched Discord binaries.

5. LICENSES
   This setup code: MIT. Vencord: GPL-3.0. DiscordTabs declares
   GPL-3.0-or-later in its source headers. Other plugins have no license
   file in their repositories. Review each repo before use.



6. PRIVACY POLICY (DETAILED)
   - Scope: this tool runs entirely on your local machine.
   - Data we collect: NONE. No telemetry, analytics, crash reports, usage
     metrics, or any tracking. We have no servers.
   - Network requests:
        0. one-line launch only: fetch install.ps1 and install.ps1.sha256
           from raw.githubusercontent.com. The GUI and console are bundled
           in install.ps1; no separate GUI download.
        1. git clone github.com/Vendicated/Vencord
        2. git clone github.com/BlockTol/Quest-Auto-Complete
        3. git clone github.com/BlockTol/Discord-Fake-Deafen
        4. git clone github.com/BlockTol/Discord-Server-Cloner
        5. git clone github.com/BlockTol/DiscordTabs
        6. git clone github.com/ScattrdBlade/bigFileUpload
        7. pnpm install -> npm registry (package downloads)
        8. optional: winget install of missing prerequisites, only if you
            click the prerequisite install button
        9. one-shot git fetch origin on launch, only when a saved target
           with a .git folder exists
       10. official VencordInstallerCli.exe release check on each inject
       11. Discord patching -> local files only, no network
    DiscordTabs checks api.github.com for its own releases at runtime and
    reads account tokens from Discord's local store. Tokens are not written
    to files or sent to a server by the plugin.


   - Stored locally: your chosen folder (source + build output), Discord's
     own config under %APPDATA%\Discord, pnpm/npm cache under your profile.
   - Third parties: Discord Inc. and GitHub may log their own requests per
     their policies. We do not control that.
   - Vencord settings sync (optional, off by default): if enabled, Vencord
     syncs via its own backend - see Vencord's own terms.
   - Rights: delete the created folder to remove all local setup data. No
     account, no registration, no data retention by us.

7. COOKIE POLICY (DETAILED)
   - This tool sets ZERO cookies, zero localStorage, zero sessionStorage,
     zero tracking identifiers of any kind.
   - Discord client may set its own session/auth cookies during normal
     operation. We do not read, modify, or transmit them.
   - Vencord may store plugin settings in Discord's local storage.
   - No cross-site cookies, no ad cookies, no analytics cookies.
   - No cookie banner is shown because none are set by us.

8. TERMS OF USE (DETAILED)
   1. AS-IS: no warranty, no guarantee of fitness for purpose.
   2. ACCOUNT RISK: client mods violate Discord ToS. You accept all risk to
      your Discord account, including bans.
   3. THIRD-PARTY CODE: plugins authored by others. Review source. We are
      not responsible.
   4. NO REDISTRIBUTION of patched Discord binaries.
   5. LICENSES: setup code MIT; Vencord GPL-3.0; DiscordTabs source headers
      declare GPL-3.0-or-later; other plugins: no license file in their
      repositories. Respect each author's rights.
 
   6. NO MALICIOUS USE: do not use to harm others or violate laws/terms.
   7. AGE: you must be old enough to use Discord in your region.
   8. ACCEPTANCE: continuing = you read and accept all terms, warnings,
      privacy policy and cookie policy above.

9. ASSETS
   Sound design references bencho.dev (names mapped to beep patterns).
   Icons reference iconoir.com (outline style). No copyrighted assets are
   shipped by us. Vencord and plugins carry their own licenses.

10. NO AFFILIATION
    This tool is not affiliated with, endorsed by, or sponsored by Discord
    Inc., Vencord, or any plugin author. All trademarks belong to their
    respective owners. "Discord" is a trademark of Discord Inc.

11. ACCEPTABLE USE POLICY (AUP)
    You agree NOT to use this tool to:
    - violate any law, regulation, or third-party terms (including Discord's).
    - harm, harass, defraud, or exploit any person.
    - distribute malware, spam, or abusive content.
    - bypass security controls of systems you do not own.
    - use it in any way that could damage our reputation or expose us to
      liability.
    Violation may end your access to future updates.

12. LICENSE GRANT
    The setup code in this repository is licensed under the MIT License.
    MIT permits use, copying, modification, merging, publication,
    distribution, sublicensing, and sale, provided the copyright notice
    and permission notice are included in copies or substantial portions.
    Third-party projects keep their own licenses. Vencord is GPL-3.0 and
    DiscordTabs declares GPL-3.0-or-later in its source headers.







13. LIMITATION OF LIABILITY
    TO THE MAXIMUM EXTENT PERMITTED BY LAW, WE (THE AUTHORS) ARE NOT
    LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR
    PUNITIVE DAMAGES, INCLUDING BUT NOT LIMITED TO: loss of Discord account,
    loss of data, loss of profits, service interruption, or any damages
    arising from use or inability to use this tool. OUR TOTAL LIABILITY
    SHALL NOT EXCEED THE AMOUNT YOU PAID FOR THIS TOOL (ZERO). SOME
    JURISDICTIONS DO NOT ALLOW THESE LIMITATIONS; IN THOSE, OUR LIABILITY
    IS LIMITED TO THE MAXIMUM EXTENT PERMITTED.

14. INDEMNIFICATION
    You agree to indemnify and hold harmless the authors from any claims,
    losses, damages, liabilities, and expenses (including legal fees)
    arising from your use of this tool, your violation of these terms, or
    your violation of any third-party rights or laws (including Discord's
    Terms of Service).

15. DISCLAIMER OF WARRANTIES
    THE TOOL IS PROVIDED "AS IS" AND "AS AVAILABLE", WITHOUT WARRANTY OF
    ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO WARRANTIES
    OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, AND
    NON-INFRINGEMENT. WE DO NOT WARRANT THAT IT WILL BE ERROR-FREE,
    UNINTERRUPTED, SECURE, OR COMPATIBLE WITH FUTURE DISCORD UPDATES.

16. TERMINATION OF UPDATES
    The MIT license for the setup code is perpetual for copies already
    distributed. We may stop publishing updates or close distribution
    channels at any time. This does not revoke rights already granted
    under the MIT License.

17. GOVERNING LAW & DISPUTE RESOLUTION
    These terms are governed by the laws of the jurisdiction in which the
    primary author resides, without regard to conflict-of-law principles.
    Any dispute shall first be attempted to be resolved informally by
    contacting the author. If unresolved, disputes shall be submitted to
    binding arbitration or the courts of that jurisdiction, as applicable.
    You waive any right to a jury trial and to participate in class actions
    to the extent permitted by law.

18. SEVERABILITY
    If any provision of these terms is held invalid or unenforceable, the
    remaining provisions continue in full force and effect.

19. ENTIRE AGREEMENT
    These terms, together with the privacy and cookie policies above,
    constitute the entire agreement between you and us regarding this
    tool and supersede all prior agreements.

20. NO WAIVER
    Failure to enforce any provision does not waive our right to enforce
    it later.

21. CHANGES TO TERMS
    We may update these terms at any time. Continued use after changes
    constitutes acceptance for future updates. Changes do not revoke the
    MIT rights already granted for distributed copies under section 12.
    The "last updated" date is shown at the top.

22. CREDITS & THIRD-PARTY ASSETS
    This tool uses and references the following. Source is cloned at run time;
    none of it is bundled here. License status is taken from each repository.
    - Vencord by Vendicated - https://github.com/Vendicated/Vencord
      License: GPL-3.0.
    - Quest-Auto-Complete by BlockTol
      https://github.com/BlockTol/Quest-Auto-Complete
      License: not stated in repository.
    - Discord-Fake-Deafen by BlockTol
      https://github.com/BlockTol/Discord-Fake-Deafen
      License: not stated in repository.
    - Discord-Server-Cloner by BlockTol
      https://github.com/BlockTol/Discord-Server-Cloner
      License: not stated in repository.
    - DiscordTabs by BlockTol
      https://github.com/BlockTol/DiscordTabs
      License: GPL-3.0-or-later in source headers; no LICENSE file.
    - bigFileUpload by ScattrdBlade
      https://github.com/ScattrdBlade/bigFileUpload
      License: not stated in repository.
    - Sounds: bencho.dev (https://bencho.dev/sounds) - synthesized
      WAV tones mapped to bencho sound names. No audio files shipped.
    - Icons: iconoir.com (https://iconoir.com) - outline SVG icons
      converted to WPF path data. MIT licensed.
    - Segoe Fluent Icons (Microsoft, Windows built-in) - fallback glyphs.
    - Node.js, Git, pnpm - their respective licenses apply.
    - Discord is a trademark of Discord Inc. (not affiliated).
    - This script and repository: MIT. Copyright (c) 2026 yetilukoss.

23. SETUP-ONLY DISCLAIMER
     The code in this repository is a setup and automation helper. Vencord and
     the user plugins are third-party projects fetched from their own
     repositories at run time. We make no claim to authorship, ownership, or
     endorsement of that code. The accurate description is: this repository
     installs and configures existing tools faster. It is not the client
     modification itself. That statement is factual. It is not a defense to a
     Terms of Service violation and should not be presented as one.

LAST UPDATED: 2026-11-22
END OF TERMS - scroll complete unlocks the agree button.
"@
$termsText.Text = $termsFull

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Log([string]$msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    $txtLog.AppendText("$line`r`n")
    $txtLog.ScrollToEnd()
    try { Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
    $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render) | Out-Null
}
function Set-Status([string]$msg) { $lblStatus.Text = $msg; $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render) | Out-Null }
function Set-Progress([int]$value) { $pb.Value = $value; $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render) | Out-Null }

function Invoke-NativeLogged {
    param([scriptblock]$Command, [string]$Prefix = '  ')
    $pref = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Command 2>&1 | ForEach-Object { if ($null -ne $_) { Log ($Prefix + $_.ToString()) } }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $pref
    }
}

function Invoke-NativeCapture {
    param([scriptblock]$Command)
    $pref = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $Command 2>&1
        $text = (($out | ForEach-Object { if ($null -ne $_) { $_.ToString() } }) -join "`n")
        return [pscustomobject]@{ Text = $text; ExitCode = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $pref
    }
}

function Get-Branch {
    if ($rbAuto -and $rbAuto.IsChecked) { return 'auto' }
    if ($rbStable -and $rbStable.IsChecked) { return 'stable' }
    if ($rbPtb -and $rbPtb.IsChecked) { return 'ptb' }
    if ($rbCanary -and $rbCanary.IsChecked) { return 'canary' }
    return 'auto'
}

function Test-SafeTarget([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($path).TrimEnd('\')
        if ($full -match '^[A-Za-z]:$') { return $false }
        $bad = @($env:SystemRoot, $env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'), $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData)
        $systemRootFull = [System.IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\')
        foreach ($b in $bad) {
            if (-not [string]::IsNullOrWhiteSpace($b)) {
                $bf = [System.IO.Path]::GetFullPath($b).TrimEnd('\')
                if ($full -ieq $bf) { return $false }
                if ($bf -ieq $systemRootFull -and $full.StartsWith($bf + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
            }
        }
        $cursor = $full
        while ($cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
            $parent = Split-Path -Parent $cursor
            if (-not $parent -or $parent -eq $cursor) { break }
            $cursor = $parent
        }
        return $true
    } catch { return $false }
}

function Invoke-UiNative {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = ''
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory } else { (Get-Location).Path }
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        while (-not $proc.HasExited) {
            $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
            Start-Sleep -Milliseconds 30
        }
        $proc.WaitForExit()
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        foreach ($line in ($stdout -split "`r?`n")) { if (-not [string]::IsNullOrWhiteSpace($line)) { Log ("  " + $line) } }
        foreach ($line in ($stderr -split "`r?`n")) { if (-not [string]::IsNullOrWhiteSpace($line)) { Log ("  ! " + $line) } }
        return [int]$proc.ExitCode
    } catch {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
        throw
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

function Invoke-UiNativeCapture {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = ''
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory } else { (Get-Location).Path }
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        while (-not $proc.HasExited) {
            $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
            Start-Sleep -Milliseconds 30
        }
        $proc.WaitForExit()
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        return [pscustomobject]@{ Text = ($stdout + "`n" + $stderr).Trim(); ExitCode = [int]$proc.ExitCode }
    } catch {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
        throw
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

function Get-DiscordResourceForBranch([string]$branch) {
    $rootName = switch ($branch) {
        'stable' { 'Discord' }
        'canary' { 'DiscordCanary' }
        'ptb'    { 'DiscordPTB' }
        default  { 'Discord' }
    }
    $roots = if ($branch -eq 'auto') {
        @(Join-Path $env:LOCALAPPDATA 'Discord'; Join-Path $env:LOCALAPPDATA 'DiscordCanary'; Join-Path $env:LOCALAPPDATA 'DiscordPTB')
    } else {
        @(Join-Path $env:LOCALAPPDATA $rootName)
    }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        $appLink = Join-Path $root 'app'
        if (Test-Path -LiteralPath $appLink) { $dirs = @($appLink) + $dirs }
        foreach ($dir in ($dirs | Sort-Object { $_ } -Descending)) {
            $resources = Join-Path $dir 'resources'
            if (Test-Path -LiteralPath (Join-Path $resources 'app.asar')) { return $resources }
        }
    }
    return $null
}

function Backup-DiscordAsarForBranch([string]$branch) {
    $resources = Get-DiscordResourceForBranch $branch
    if (-not $resources) { Log "  WARN: Discord resources not found for $branch; skipping asar backup."; return }
    $asar = Join-Path $resources 'app.asar'
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupRoot = Join-Path $env:APPDATA 'VencordSetup\Backups'
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backup = Join-Path $backupRoot ("app.asar." + $branch + "." + $stamp)
    Copy-Item -LiteralPath $asar -Destination $backup -Force
    if (-not (Test-Path -LiteralPath $backup)) { throw "Could not back up app.asar for $branch." }
    Log "  backup created: $backup"
}
function Invoke-VencordCli {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$Branch = 'auto',
        [switch]$Uninstall
    )
    $cli = Join-Path $Target 'dist\Installer\VencordInstallerCli.exe'
    $oldData = $env:VENCORD_USER_DATA_DIR
    $oldDev = $env:VENCORD_DEV_INSTALL
    try {
        $env:VENCORD_USER_DATA_DIR = $Target
        $env:VENCORD_DEV_INSTALL = '1'
        Log "  checking installer CLI (official Vencord/Installer release)..."
        $rc = Invoke-UiNative -FilePath 'node' -Arguments 'scripts/runInstaller.mjs -- -version' -WorkingDirectory $Target
        if ($rc -ne 0 -or -not (Test-Path -LiteralPath $cli)) { throw "Could not obtain Vencord installer CLI." }
        Backup-DiscordAsarForBranch $Branch
        $modeArg = if ($Uninstall) { '-uninstall' } else { '-install' }
        $cliArgs = "-branch $Branch $modeArg"
        $rc = Invoke-UiNative -FilePath $cli -Arguments $cliArgs -WorkingDirectory $Target
        if ($rc -ne 0) { throw "Vencord CLI failed (exit $rc)." }
        return $true
    } finally {
        $env:VENCORD_USER_DATA_DIR = $oldData
        $env:VENCORD_DEV_INSTALL = $oldDev
    }
}

function Set-Busy([bool]$busy) {
    foreach ($c in $script:BusyControls) { if ($c) { $c.IsEnabled = -not $busy } }
}
$script:BusyControls = @(
    $btnInstall, $btnRepair, $btnUninstall, $btnUpdate, $btnReinject,
    $btnBrowse, $btnRecheck, $btnWinget, $btnExportLog, $btnClearLog,
    $btnSelectAll, $btnClearAll, $chkQAC, $chkFakeDeafen, $chkCloner,
    $chkDiscordTabs, $chkBigFileUpload, $chkSound, $chkDryRun,
    $rbAuto, $rbStable, $rbPtb, $rbCanary
)

function Remove-NestedDuplicate([string]$dir, [string]$name) {
    foreach ($candidate in @($name, ($name -replace '-', ''))) {
        $nested = Join-Path $dir $candidate
        if (-not (Test-Path -LiteralPath $nested)) { continue }
        $hasIndex = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^index\.tsx?$' }).Count -gt 0
        $isRepo = Test-Path -LiteralPath (Join-Path $nested '.git')
        if ($hasIndex -or -not $isRepo) { Log "  keeping nested $candidate (source, not duplicate)."; continue }
        Log "  removing nested duplicate: $nested"
        try { Remove-Item -LiteralPath $nested -Recurse -Force -ErrorAction Stop } catch { Log "  WARN: could not remove $nested" }
    }
}

# ----------------------------------------------------------------------------
# Terms scroll gating
# ----------------------------------------------------------------------------
$script:TermsAccepted = $false
function Update-AgreeState {
    $sv = $termsScroll
    $was = $btnAgree.IsEnabled
    if ($sv.ExtentHeight -le $sv.ViewportHeight) {
        $btnAgree.IsEnabled = -not $script:TermsAccepted
    } else {
        $atBottom = ($sv.VerticalOffset + $sv.ViewportHeight) -ge ($sv.ExtentHeight - 2)
        $btnAgree.IsEnabled = $atBottom -and (-not $script:TermsAccepted)
    }
    if (-not $was -and $btnAgree.IsEnabled) { [System.Windows.Input.Keyboard]::Focus($btnAgree) }
}
try {
    $window.Dispatcher.add_UnhandledException({
        param($sender, $e)
        try { Log "UNHANDLED: $($e.Exception.Message)" } catch { }
        $e.Handled = $true
    })
} catch { }
$termsScroll.Add_ScrollChanged({ Update-AgreeState })
$window.Add_ContentRendered({
    $window.Dispatcher.BeginInvoke([Action]{
        Update-AgreeState
        [System.Windows.Input.Keyboard]::Focus($btnDecline)
        Check-Updates
    }, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
})

$btnAgree.Add_Click({
    Play-Sound 'click'
    $script:TermsAccepted = $true
    $btnAgree.IsEnabled = $false
    $btnAgree.Visibility = 'Collapsed'
    $btnNext.Visibility = 'Visible'
    [System.Windows.Input.Keyboard]::Focus($btnNext)
    Log "Terms accepted."
})
$btnDecline.Add_Click({
    Play-Sound 'error'
    $window.Close()
})
$btnNext.Add_Click({
    Play-Sound 'navigate'
    $tabs.IsEnabled = $true
    $tabs.Effect = $null
    $overlay.Visibility = 'Collapsed'
    $script:TermsAccepted = $true
    [System.Windows.Input.Keyboard]::Focus($tabs)
})

$blur = New-Object System.Windows.Media.Effects.BlurEffect
$blur.Radius = 6
$tabs.Effect = $blur

# ----------------------------------------------------------------------------
# Prerequisite check
# ----------------------------------------------------------------------------
function Test-PrereqCmd([string]$cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Update-Prereqs {
    $nodeOk = Test-PrereqCmd 'node'
    $gitOk  = Test-PrereqCmd 'git'
    $pnpmOk = Test-PrereqCmd 'pnpm'

    if ($nodeOk) {
        $nodeVer = (Invoke-NativeCapture { node --version }).Text.Trim()
        $nodeMajor = 0
        $nodeRaw = $nodeVer -replace '^v','' -split '\.'
        if (-not [int]::TryParse($nodeRaw[0], [ref]$nodeMajor)) { $nodeMajor = 0 }
        if ($nodeMajor -lt 22) { $nodeVer = "$nodeVer  (need >=22)" }
    } else { $nodeVer = "MISSING - https://nodejs.org" }
    if ($gitOk)  { $gitVer  = (Invoke-NativeCapture { git --version }).Text.Trim() } else { $gitVer = "MISSING - https://git-scm.com" }
    if ($pnpmOk) { $pnpmVer = (Invoke-NativeCapture { pnpm --version }).Text.Trim() } else { $pnpmVer = "MISSING - run: npm install -g pnpm" }

    $lblNode.Text = ("Node.js: " + $nodeVer)
    $lblGit.Text  = ("Git: " + $gitVer)
    $lblPnpm.Text = ("pnpm: " + $pnpmVer)

    if ($nodeOk) { $lblNode.Foreground = (Get-WpfBrush '#a6e3a1') } else { $lblNode.Foreground = (Get-WpfBrush '#f38ba8') }
    if ($gitOk)  { $lblGit.Foreground  = (Get-WpfBrush '#a6e3a1') } else { $lblGit.Foreground  = (Get-WpfBrush '#f38ba8') }
    if ($pnpmOk) { $lblPnpm.Foreground= (Get-WpfBrush '#a6e3a1') } else { $lblPnpm.Foreground= (Get-WpfBrush '#f38ba8') }
}
$btnRecheck.Add_Click({ Play-Sound 'click'; Update-Prereqs; Log "Prerequisites re-checked." })
$btnWinget.Add_Click({
    Play-Sound 'click'
    if ($chkDryRun.IsChecked) {
        Log "DRY-RUN: would install missing prerequisites."
        Play-Sound 'success'
        return
    }
    Log "=== winget install missing prerequisites ==="
    $toInstall = @()
    if (-not (Test-PrereqCmd 'node')) { $toInstall += 'OpenJS.NodeJS.LTS' }
    if (-not (Test-PrereqCmd 'git'))  { $toInstall += 'Git.Git' }
    $pnpmMissing = -not (Test-PrereqCmd 'pnpm')
    if ($toInstall.Count -eq 0 -and -not $pnpmMissing) { Log "  All prerequisites present."; Play-Sound 'success'; return }
    if ($toInstall.Count -gt 0 -and -not (Test-PrereqCmd 'winget')) {
        Log "  WARN: winget not found. Install Node.js and Git manually."
        Play-Sound 'warning'
    } else {
        foreach ($pkg in $toInstall) {
            Log "  winget install $pkg ..."
            try {
                $rc = Invoke-UiNative -FilePath 'winget' -Arguments "install --id $pkg -e --silent --accept-package-agreements --accept-source-agreements"
                if ($rc -ne 0) { Log "  WARN: winget exit $rc for $pkg"; Play-Sound 'warning' }
                else { Log "  OK: $pkg"; Play-Sound 'success' }
            } catch {
                Log "  WARN: winget failed for $pkg`: $($_.Exception.Message)"
                Play-Sound 'warning'
            }
        }
    }
    if ($pnpmMissing) {
        Log "  installing pnpm via npm..."
        $rc = Invoke-NativeLogged { cmd.exe /c "npm install -g pnpm" } -Prefix '  '
        if ($rc -ne 0) { Log "  WARN: npm exited $rc"; Play-Sound 'warning' }
        else { Log "  OK: pnpm"; Play-Sound 'success' }
    }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    $userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    if ($machinePath -or $userPath) { $env:PATH = "$machinePath;$userPath" }
    Update-Prereqs
    Log "  Done. PATH refreshed in this session."
})
Update-Prereqs

# Auto-update check on launch
function Check-Updates {
    $target = $txtPath.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path (Join-Path $target '.git'))) { 
        $lblUpdateStatus.Text = ""
        return 
    }
    $lblUpdateStatus.Text = "Checking for updates..."
    $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render) | Out-Null
    try {
        $fetch = Invoke-UiNativeCapture -FilePath 'git' -Arguments 'fetch origin' -WorkingDirectory $target
        if ($fetch.ExitCode -ne 0) { throw "git fetch failed" }
        $localRes = Invoke-UiNativeCapture -FilePath 'git' -Arguments 'rev-parse HEAD' -WorkingDirectory $target
        $remoteRes = Invoke-UiNativeCapture -FilePath 'git' -Arguments 'rev-parse @{u}' -WorkingDirectory $target
        $local = $localRes.Text.Trim()
        $remote = $remoteRes.Text.Trim()
        if (-not $remoteRes -or $remoteRes.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($remote)) {
            $lblUpdateStatus.Text = "Update status unknown (no upstream)."
            $lblUpdateStatus.Foreground = (Get-WpfBrush '#a6adc8')
        } elseif ($local -and $remote -and $local -ne $remote) {
            $lblUpdateStatus.Text = "Update available: $local -> $remote (use Update button)"
            $lblUpdateStatus.Foreground = (Get-WpfBrush '#f9e2af')
        } else {
            $lblUpdateStatus.Text = "Up to date."
            $lblUpdateStatus.Foreground = (Get-WpfBrush '#a6e3a1')
        }
    } catch {
        $lblUpdateStatus.Text = "Update check failed."
        $lblUpdateStatus.Foreground = (Get-WpfBrush '#f38ba8')
    }
}

# ----------------------------------------------------------------------------
# Folder browse
# ----------------------------------------------------------------------------
$btnBrowse.Add_Click({
    Play-Sound 'click'
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Select parent folder for the Vencord setup"
        $dlg.RootFolder = [System.Environment+SpecialFolder]::Desktop
        $dlg.ShowNewFolderButton = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $dlg.SelectedPath) {
            $txtPath.Text = Join-Path $dlg.SelectedPath 'Vencord'
            $lblPathStatus.Text = "Selected: $($dlg.SelectedPath)"
            Play-Sound 'success'
            Save-Settings
        }
    } catch {
        Log "WARN: folder browse failed: $($_.Exception.Message)"
        Play-Sound 'warning'
    }
})

# ----------------------------------------------------------------------------
# Log export
# ----------------------------------------------------------------------------
$btnExportLog.Add_Click({
    Play-Sound 'click'
    try {
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
        $dlg.FileName = "VencordSetup.log"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtLog.Text | Set-Content -Path $dlg.FileName -Encoding UTF8
            Log "Log exported to $($dlg.FileName)"
            Play-Sound 'success'
        }
    } catch {
        Log "WARN: log export failed: $($_.Exception.Message)"
        Play-Sound 'warning'
    }
})

$btnClearLog.Add_Click({
    Play-Sound 'click'
    $txtLog.Clear()
})

# ----------------------------------------------------------------------------
# Install / repair / uninstall / update helpers
# ----------------------------------------------------------------------------
function Repair-PluginCompat([string]$up) {
    if (-not $up -or -not (Test-Path $up)) { return }
    $patches = @(
        @{
            File = 'Discord-Fake-Deafen\index.tsx'
            Rules = @(
                @{ Old = 'import { Button, Menu, React } from "@webpack/common";'; New = "import { Button } from `"@components/Button`";`nimport { Menu, React } from `"@webpack/common`";" }
                @{ Old = 'import { ModalContent, ModalFooter, ModalHeader, ModalProps, ModalRoot, openModal } from "@utils/modal";'; New = "import { ModalContent, ModalFooter, ModalHeader, ModalRoot, openModal } from `"@utils/modal`";`nimport type { RenderModalProps as ModalProps } from `"@vencord/discord-types`";" }
                @{ Old = '<Button color={Button.Colors.PRIMARY}'; New = '<Button variant="secondary"' }
                @{ Old = '<Button color={Button.Colors.GREEN}'; New = '<Button variant="positive"' }
            )
        }
        @{
            File = 'Discord-Server-Cloner\components\CloneModal.tsx'
            Rules = @(
                @{ Old = 'import { React, GuildStore, GuildRoleStore, UserStore, SearchableSelect, Checkbox, Button } from "@webpack/common";'; New = "import { Button } from `"@components/Button`";`nimport { React, GuildStore, GuildRoleStore, UserStore, SearchableSelect, Checkbox } from `"@webpack/common`";" }
                @{ Old = 'import { ModalContent, ModalFooter, ModalHeader, ModalProps, ModalRoot, openModal } from "@utils/modal";'; New = "import { ModalContent, ModalFooter, ModalHeader, ModalRoot, openModal } from `"@utils/modal`";`nimport type { RenderModalProps as ModalProps } from `"@vencord/discord-types`";" }
                @{ Old = 'color={Button.Colors.PRIMARY}'; New = 'variant="secondary"' }
                @{ Old = 'color={Button.Colors.RED}'; New = 'variant="dangerPrimary"' }
                @{ Old = 'color={Button.Colors.BRAND}'; New = 'variant="primary"' }
            )
        }
    )
    foreach ($patch in $patches) {
        $f = Join-Path $up $patch.File
        if (-not (Test-Path $f)) { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($f)
            $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
            $changed = $false
            foreach ($rule in $patch.Rules) {
                if ($raw.Contains($rule.New)) { continue }
                $count = ([regex]::Matches($raw, [regex]::Escape($rule.Old))).Count
                if ($count -eq 0) { continue }
                $raw = $raw.Replace($rule.Old, $rule.New.Replace("`n", $nl))
                $changed = $true
                Log "  compat patch: $($patch.File) [$count hit(s)]"
            }
            if ($changed) { [System.IO.File]::WriteAllText($f, $raw, (New-Object System.Text.UTF8Encoding($false))) }
        } catch {
            Log "  WARN: compat patch failed for $($patch.File): $($_.Exception.Message)"
        }
    }
}

function Invoke-InstallCore([string]$target, [array]$enabled, [bool]$isUpdate) {
    $script:DryRun = [bool]$chkDryRun.IsChecked
    Set-Busy $true

    try {
        if (-not $script:DryRun) {
            foreach ($c in @('node','git','pnpm')) {
                if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
                    throw "Missing prerequisite: $c. Install it, then re-run."
                }
            }
            $nodeRaw = (Invoke-NativeCapture { node --version }).Text.Trim().TrimStart('v')
            $nodeMajor = 0
            if (-not [int]::TryParse(($nodeRaw -split '\.')[0], [ref]$nodeMajor) -or $nodeMajor -lt 22) {
                throw "Node.js >= 22 required. Found: $nodeRaw"
            }
        }
        $txtLog.Clear()
        $branch = Get-Branch
        Log "=== VencordSetup started ==="
        Log "Target: $target"
        Log "Plugins: $($enabled.Name -join ', ')"
        Set-Progress 0

        if ($script:DryRun) {
            Log "DRY-RUN MODE: no changes will be made."
            if ($isUpdate) {
                Log "  would pull Vencord core and each userplugin repo"
            } else {
                Log "  would clone Vencord -> $target"
                foreach ($pl in $enabled) { Log "  would clone $($pl.Repo) -> $(Join-Path (Join-Path $target 'src\userplugins') $pl.Name)" }
                Log "  would create $(Join-Path $target 'src\userplugins')"
            }
            Log "  would repair plugin compatibility"
            Log "  would run pnpm install and pnpm build"
            Log "  would inject into Discord ($branch)"
            Set-Progress 100
            Set-Status "Dry run complete."
            Log "=== DRY RUN COMPLETE ==="
            Play-Sound 'success'
            return
        }

        $up = Join-Path $target 'src\userplugins'
        if (-not $isUpdate) {
            if (-not (Test-SafeTarget $target)) { throw "Refusing to use unsafe target path: $target" }
            if (Test-Path -LiteralPath $target) {
                $items = Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue
                if ($items) {
                    $ov = [System.Windows.MessageBox]::Show("Folder exists and is not empty. Overwrite?", "VencordSetup", 'YesNo', 'Warning')
                    if ($ov -ne 'Yes') { Log "Aborted by user."; Play-Sound 'error'; return }
                    $bakName = 'Vencord.bak_' + (Get-Date -Format 'yyyyMMdd-HHmmss')
                    $bakPath = Join-Path (Split-Path -Parent $target) $bakName
                    Rename-Item -LiteralPath $target -NewName $bakName
                    Log "  existing folder preserved: $bakPath"
                }
            }
            New-Item -ItemType Directory -Path $target -Force | Out-Null

            Set-Status "Cloning Vencord..."
            Log "[1/6] git clone Vencord..."
            Set-Progress 10
            $rc = Invoke-UiNative -FilePath 'git' -Arguments "clone https://github.com/Vendicated/Vencord `"$target`""
            if ($rc -ne 0) { throw "Vencord clone failed (exit $rc)" }
            Log "  OK"
            Play-Sound 'success'

            New-Item -ItemType Directory -Path $up -Force | Out-Null
            $step = 2
            foreach ($pl in $enabled) {
                Set-Status "Cloning $($pl.Name)..."
                Log "[$step/6] git clone $($pl.Name)..."
                Set-Progress (15 + ($step-2)*5)
                $dest = Join-Path $up $pl.Name
                $rc = Invoke-UiNative -FilePath 'git' -Arguments "clone $($pl.Repo) `"$dest`""
                if ($rc -ne 0) { Log "  WARN: clone failed, skipping."; Play-Sound 'warning'; $step++; continue }
                Log "  OK"
                Remove-NestedDuplicate $dest $pl.Name
                Play-Sound 'success'
                $step++
            }
            Log "  userplugins folder ready: $up"
        } else {
            if (-not (Test-SafeTarget $target)) { throw "Refusing to use unsafe target path: $target" }
            if (-not (Test-Path -LiteralPath $target)) { throw "Target folder does not exist: $target" }
            Log "Update mode: syncing selected plugins + Vencord..."
            if (-not (Test-Path -LiteralPath $up)) { New-Item -ItemType Directory -Path $up -Force | Out-Null }
            $wanted = @($enabled | ForEach-Object { $_.Name })
            foreach ($pl in $enabled) {
                $dest = Join-Path $up $pl.Name
                if (-not (Test-Path -LiteralPath (Join-Path $dest '.git'))) {
                    Log "  cloning missing plugin: $($pl.Name)"
                    $rc = Invoke-UiNative -FilePath 'git' -Arguments "clone $($pl.Repo) `"$dest`""
                    if ($rc -ne 0) { throw "Plugin clone failed: $($pl.Name)" }
                }
            }
            Get-ChildItem -LiteralPath $up -Directory | ForEach-Object {
                $pluginDir = $_.FullName
                $pluginName = $_.Name
                if ($wanted -notcontains $pluginName) { Log "  skipped (not selected): $pluginName"; return }
                if (-not (Test-Path -LiteralPath (Join-Path $pluginDir '.git'))) { return }
                Log "  -> $pluginName"
                $status = Invoke-UiNativeCapture -FilePath 'git' -Arguments 'status --porcelain' -WorkingDirectory $pluginDir
                $stashed = $false
                if ($status.Text) {
                    $stashRes = Invoke-UiNativeCapture -FilePath 'git' -Arguments 'stash push -u -m "VencordSetupGUI auto-stash"' -WorkingDirectory $pluginDir
                    if ($stashRes.ExitCode -eq 0) { $stashed = $true }
                }
                $pullRes = Invoke-UiNativeCapture -FilePath 'git' -Arguments 'pull --ff-only' -WorkingDirectory $pluginDir
                if ($pullRes.ExitCode -ne 0) { Log "     WARN: pull failed for $pluginName"; Play-Sound 'warning' }
                if ($stashed) {
                    $pop = Invoke-UiNativeCapture -FilePath 'git' -Arguments 'stash pop' -WorkingDirectory $pluginDir
                    if ($pop.ExitCode -ne 0) { throw "Stash pop conflict in $pluginName. Resolve manually before updating." }
                }
                Remove-NestedDuplicate $pluginDir $pluginName
            }

            Log "  -> Vencord (core)"
            $coreRes = Invoke-UiNativeCapture -FilePath 'git' -Arguments 'pull --ff-only' -WorkingDirectory $target
            if ($coreRes.ExitCode -ne 0) { throw "Vencord pull failed" }
        }

        Repair-PluginCompat $up

        $pkgPath = Join-Path $target 'package.json'
        if (-not (Test-Path -LiteralPath $pkgPath)) {
            throw "Vencord clone layout is wrong: no package.json at $target. Aborting before pnpm."
        }
        try {
            $pkgData = Get-Content -LiteralPath $pkgPath -Raw | ConvertFrom-Json
            if (-not $pkgData.scripts -or -not $pkgData.scripts.build) {
                throw "Vencord package.json has no build script at $target. Aborting before pnpm."
            }
        } catch {
            throw "Could not read Vencord package.json at $target. $($_.Exception.Message)"
        }

        Set-Status "pnpm install..."
        Log "[install 1/3] pnpm install..."
        Set-Progress 40
        $pb.IsIndeterminate = $true
        Set-Status "pnpm install (this may take a while)..."
        Push-Location $target
        try {
            $rc = Invoke-UiNative -FilePath 'cmd.exe' -Arguments '/c pnpm install' -WorkingDirectory $target
            if ($rc -ne 0) { throw "pnpm install failed (exit $rc)" }
            Log "  OK"
            Play-Sound 'success'
            $pb.IsIndeterminate = $false
            Set-Progress 60

            Set-Status "pnpm build..."
            Log "[install 2/3] pnpm build..."
            Set-Progress 65
            $pb.IsIndeterminate = $true
            Set-Status "pnpm build (compiling, may take a while)..."
            $rc = Invoke-UiNative -FilePath 'cmd.exe' -Arguments '/c pnpm build' -WorkingDirectory $target
            if ($rc -ne 0) { throw "pnpm build failed (exit $rc)" }
            Log "  OK"
            Play-Sound 'success'
            $pb.IsIndeterminate = $false
            Set-Progress 82

            Log "  checking plugin bundle presence..."
            $bundle = Join-Path $target 'dist\vencordDesktopRenderer.js'
            if (Test-Path $bundle) {
                $content = Get-Content $bundle -Raw -ErrorAction SilentlyContinue
                foreach ($pl in $enabled) {
                    $needles = @($pl.Name -replace '-','')
                    $srcDir = Join-Path $up $pl.Name
                    if (Test-Path $srcDir) {
                        $declared = Get-ChildItem -Path $srcDir -Recurse -File -Include '*.ts','*.tsx' -ErrorAction SilentlyContinue | ForEach-Object {
                            $text = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                            if ($text) { [regex]::Matches($text, 'name:\s*["'']([^"'']+)["'']') | ForEach-Object { $_.Groups[1].Value } }
                        }
                        $needles += @($declared | Where-Object { $_ } | Sort-Object -Unique)
                    }
                    $found = $false
                    foreach ($needle in $needles) {
                        if ($needle -and $content -match [regex]::Escape($needle)) { $found = $true; break }
                    }
                    if ($found) { Log "    OK: $($pl.Name)" }
                    else { Log "    WARN: $($pl.Name) not found in bundle"; Play-Sound 'warning' }
                }
            } else { Log "    (bundle not found, skipping check)" }

            Set-Status "Injecting into Discord ($branch)..."
            Log "[install 3/3] inject ($branch)..."
            Set-Progress 85
            $pb.IsIndeterminate = $true

            Invoke-VencordCli -Target $target -Branch $branch
            Log "  inject OK"
            Play-Sound 'success'
        } finally {
            Pop-Location
            $pb.IsIndeterminate = $false
        }

        Set-Progress 100
        Set-Status "Done."
        Log "=== DONE === Restart Discord fully, then enable plugins in Settings -> Plugins."
        Play-Sound 'complete'
    } catch {
        $pb.IsIndeterminate = $false
        Log "ERROR: $($_.Exception.Message)"
        Set-Status "Failed."
        Play-Sound 'error'
        [System.Windows.MessageBox]::Show($_.Exception.Message, "VencordSetup", 'OK', 'Error') | Out-Null
    } finally {
        Set-Busy $false
    }
}

$btnInstall.Add_Click({
    if (-not $script:TermsAccepted) {
        [System.Windows.MessageBox]::Show("Accept the terms first.", "VencordSetup", 'OK', 'Warning') | Out-Null
        Play-Sound 'warning'
        return
    }
    $target = $txtPath.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($target)) {
        [System.Windows.MessageBox]::Show("Choose an install folder first.", "VencordSetup", 'OK', 'Warning') | Out-Null
        Play-Sound 'warning'
        return
    }

    $script:SoundEnabled = [bool]$chkSound.IsChecked
    $enabled = @()
    if ($chkQAC.IsChecked)         { $enabled += @{ Name='Quest-Auto-Complete'; Repo='https://github.com/BlockTol/Quest-Auto-Complete.git' } }
    if ($chkFakeDeafen.IsChecked)  { $enabled += @{ Name='Discord-Fake-Deafen';  Repo='https://github.com/BlockTol/Discord-Fake-Deafen.git' } }
    if ($chkCloner.IsChecked)      { $enabled += @{ Name='Discord-Server-Cloner';Repo='https://github.com/BlockTol/Discord-Server-Cloner.git' } }
    if ($chkDiscordTabs.IsChecked) { $enabled += @{ Name='DiscordTabs'; Repo='https://github.com/BlockTol/DiscordTabs.git' } }
    if ($chkBigFileUpload.IsChecked){ $enabled += @{ Name='bigFileUpload'; Repo='https://github.com/ScattrdBlade/bigFileUpload.git' } }

    if ($enabled.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Select at least one plugin.", "VencordSetup", 'OK', 'Warning') | Out-Null
        return
    }

    $confirm = [System.Windows.MessageBox]::Show("Install Vencord + $($enabled.Count) plugin(s) into:`n$target`n`nProceed?", "VencordSetup", 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { Play-Sound 'error'; return }

    Save-Settings
    Play-Sound 'navigate'
    $btnInstall.IsEnabled = $false
    Invoke-InstallCore -target $target -enabled $enabled -isUpdate $false
})

$btnRepair.Add_Click({
    $target = $txtPath.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target) -or -not (Test-SafeTarget $target)) {
        [System.Windows.MessageBox]::Show("Target folder does not exist. Run a full install first.", "VencordSetup", 'OK', 'Warning') | Out-Null
        return
    }
    if ($chkDryRun.IsChecked) {
        Log "DRY-RUN: would pull Vencord, build, and inject."
        Play-Sound 'success'
        return
    }
    $confirm = [System.Windows.MessageBox]::Show("Repair Vencord core? (git pull + build + inject)`n$target", "VencordSetup", 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }
    Save-Settings
    Play-Sound 'navigate'
    Set-Busy $true
    $pushed = $false
    try {
        Push-Location $target
        $pushed = $true
        Log "=== REPAIR CORE ==="
        Set-Progress 10
        Log "  git pull (core)..."
        $pullRc = Invoke-NativeLogged { git pull --ff-only } -Prefix '  '
        if ($pullRc -ne 0) { throw "git pull failed (exit $pullRc)" }
        Set-Progress 40
        $pb.IsIndeterminate = $true
        Set-Status "pnpm build..."
        $rc = Invoke-UiNative -FilePath 'cmd.exe' -Arguments '/c pnpm build' -WorkingDirectory $target
        if ($rc -ne 0) { throw "pnpm build failed (exit $rc)" }
        Log "  build OK"
        $pb.IsIndeterminate = $false
        Set-Progress 70
        Set-Status "injecting..."
        $branch = Get-Branch
        Invoke-VencordCli -Target $target -Branch $branch
        Log "  inject OK"
        Set-Progress 100
        Set-Status "Repaired."
        Log "=== REPAIR DONE ==="
        Play-Sound 'success'
    } catch {
        $pb.IsIndeterminate = $false
        Log "ERROR: $($_.Exception.Message)"
        $errFile = Join-Path ([Environment]::GetFolderPath('Desktop')) "VencordRepairError_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        try { $txtLog.Text | Set-Content -Path $errFile -Encoding UTF8; Log "  error log written to: $errFile" } catch { Log "  WARN: could not write error log" }
        Play-Sound 'error'
        [System.Windows.MessageBox]::Show("Repair failed.`nError log saved to desktop: $errFile", "VencordSetup", 'OK', 'Error') | Out-Null
    } finally {
        if ($pushed) { Pop-Location }
        Set-Busy $false
        Set-Progress 100
    }
})

$btnUninstall.Add_Click({
    $target = $txtPath.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target) -or -not (Test-SafeTarget $target)) {
        [System.Windows.MessageBox]::Show("Target folder does not exist.", "VencordSetup", 'OK', 'Warning') | Out-Null
        return
    }
    if ($chkDryRun.IsChecked) {
        Log "DRY-RUN: would uninstall from Discord and delete $target"
        Play-Sound 'success'
        return
    }
    $confirm = [System.Windows.MessageBox]::Show("Uninstall Vencord from Discord AND delete the folder (full wipe)?`n$target", "VencordSetup", 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }
    Play-Sound 'navigate'
    Set-Busy $true
    $pushed = $false
    try {
        Push-Location $target
        $pushed = $true
        Log "=== UNINSTALL (full wipe) ==="
        Invoke-VencordCli -Target $target -Uninstall
        Log "  OK"
        Play-Sound 'success'
        if ($pushed) { Pop-Location; $pushed = $false }
        Log "  deleting folder: $target"
        try { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop } catch { throw "Folder delete failed: $($_.Exception.Message)" }
        if (Test-Path -LiteralPath $target) { throw "Folder still exists after delete." }
        Log "  folder deleted."
        Play-Sound 'success'
    } catch {
        Log "ERROR: $($_.Exception.Message)"; Play-Sound 'error'
    } finally {
        if ($pushed) { Pop-Location }
        Set-Busy $false
        Set-Progress 100
    }
})

$btnUpdate.Add_Click({
    $target = $txtPath.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target) -or -not (Test-SafeTarget $target)) {
        [System.Windows.MessageBox]::Show("Target folder does not exist. Run a full install first.", "VencordSetup", 'OK', 'Warning') | Out-Null
        return
    }
    $confirm = [System.Windows.MessageBox]::Show("Update: git pull + pnpm install + build + inject?`n$target", "VencordSetup", 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }
    Save-Settings
    Play-Sound 'navigate'
    Set-Busy $true
    $enabled = @()
    if ($chkQAC.IsChecked)         { $enabled += @{ Name='Quest-Auto-Complete'; Repo='https://github.com/BlockTol/Quest-Auto-Complete.git' } }
    if ($chkFakeDeafen.IsChecked)  { $enabled += @{ Name='Discord-Fake-Deafen';  Repo='https://github.com/BlockTol/Discord-Fake-Deafen.git' } }
    if ($chkCloner.IsChecked)      { $enabled += @{ Name='Discord-Server-Cloner';Repo='https://github.com/BlockTol/Discord-Server-Cloner.git' } }
    if ($chkDiscordTabs.IsChecked) { $enabled += @{ Name='DiscordTabs'; Repo='https://github.com/BlockTol/DiscordTabs.git' } }
    if ($chkBigFileUpload.IsChecked){ $enabled += @{ Name='bigFileUpload'; Repo='https://github.com/ScattrdBlade/bigFileUpload.git' } }
    Invoke-InstallCore -target $target -enabled $enabled -isUpdate $true
})

$btnReinject.Add_Click({
    $target = $txtPath.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target) -or -not (Test-SafeTarget $target)) {
        [System.Windows.MessageBox]::Show("Target folder does not exist. Run a full install first.", "VencordSetup", 'OK', 'Warning') | Out-Null
        return
    }
    if ($chkDryRun.IsChecked) {
        $branch = Get-Branch
        Log "DRY-RUN: would run pnpm build and inject into Discord ($branch)."
        Play-Sound 'success'
        return
    }
    $confirm = [System.Windows.MessageBox]::Show("Re-inject plugins: pnpm build + inject?`n$target", "VencordSetup", 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }
    Save-Settings
    Play-Sound 'navigate'
    Set-Busy $true
    $pushed = $false
    try {
        Push-Location $target
        $pushed = $true
        Log "=== RE-INJECT PLUGINS (build + inject) ==="
        Set-Progress 10
        Set-Status "pnpm build..."
        $pb.IsIndeterminate = $true
        $rc = Invoke-UiNative -FilePath 'cmd.exe' -Arguments '/c pnpm build' -WorkingDirectory $target
        if ($rc -ne 0) { throw "pnpm build failed (exit $rc)" }
        Log "  build OK"
        $pb.IsIndeterminate = $false
        Set-Progress 70
        Set-Status "injecting..."
        $branch = Get-Branch
        Invoke-VencordCli -Target $target -Branch $branch
        Log "  inject OK"
        Play-Sound 'success'
        Set-Progress 100
        Set-Status "Done."
        Log "=== DONE ==="
        Play-Sound 'complete'
    } catch {
        $pb.IsIndeterminate = $false
        Log "ERROR: $($_.Exception.Message)"; Play-Sound 'error'
        [System.Windows.MessageBox]::Show($_.Exception.Message, "VencordSetup", 'OK', 'Error') | Out-Null
    } finally {
        if ($pushed) { Pop-Location }
        Set-Busy $false
    }
})

# ----------------------------------------------------------------------------
# Load settings on startup
# ----------------------------------------------------------------------------
$settings = Load-Settings
if ($settings) {
    if ($settings.Path) { $txtPath.Text = $settings.Path }
    if ($null -ne $settings.PluginQAC)       { $chkQAC.IsChecked = [bool]$settings.PluginQAC }
    if ($null -ne $settings.PluginFakeDeafen){ $chkFakeDeafen.IsChecked = [bool]$settings.PluginFakeDeafen }
    if ($null -ne $settings.PluginCloner)    { $chkCloner.IsChecked = [bool]$settings.PluginCloner }
    if ($null -ne $settings.PluginDiscordTabs)   { $chkDiscordTabs.IsChecked = [bool]$settings.PluginDiscordTabs }
    if ($null -ne $settings.PluginBigFileUpload) { $chkBigFileUpload.IsChecked = [bool]$settings.PluginBigFileUpload }
    if ($null -ne $settings.SoundEnabled)    { $chkSound.IsChecked = [bool]$settings.SoundEnabled; $script:SoundEnabled = [bool]$settings.SoundEnabled }
    if ($null -ne $settings.DryRun)         { $chkDryRun.IsChecked = [bool]$settings.DryRun }
    if ($settings.Branch) {
        switch ($settings.Branch) {
            'stable' { $rbStable.IsChecked = $true }
            'ptb'    { $rbPtb.IsChecked = $true }
            'canary' { $rbCanary.IsChecked = $true }
            default    { $rbAuto.IsChecked = $true }
        }
    }
}

Update-PluginCount
foreach ($c in @($chkQAC, $chkFakeDeafen, $chkCloner, $chkDiscordTabs, $chkBigFileUpload)) {
    $c.Add_Checked({ Update-PluginCount })
    $c.Add_Unchecked({ Update-PluginCount })
}
$btnSelectAll.Add_Click({
    $chkQAC.IsChecked = $true; $chkFakeDeafen.IsChecked = $true; $chkCloner.IsChecked = $true; $chkDiscordTabs.IsChecked = $true; $chkBigFileUpload.IsChecked = $true
    Update-PluginCount
    Play-Sound 'click'
})
$btnClearAll.Add_Click({
    $chkQAC.IsChecked = $false; $chkFakeDeafen.IsChecked = $false; $chkCloner.IsChecked = $false; $chkDiscordTabs.IsChecked = $false; $chkBigFileUpload.IsChecked = $false
    Update-PluginCount
    Play-Sound 'click'
})

$chkSound.Add_Checked({ $script:SoundEnabled = $true; Play-Sound 'click' })
$chkSound.Add_Unchecked({ Play-Sound 'click'; $script:SoundEnabled = $false })

$window.Add_Closing({
    try { Save-Settings } catch { }
    try {
        foreach ($t in @($script:SoundTimers)) { try { $t.Stop() } catch { } }
        foreach ($k in @($script:SoundKeepAlive.Keys)) {
            $item = $script:SoundKeepAlive[$k]
            try { $item.Player.Stop() } catch { }
            try { $item.Stream.Dispose() } catch { }
        }
        $script:SoundKeepAlive.Clear()
        $script:SoundTimers.Clear()
    } catch { }
})

# Drag-and-drop folder onto window sets install path
$window.AllowDrop = $true
$window.Add_Drop({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
        if ($files -and $files.Count -gt 0 -and (Test-Path $files[0] -PathType Container)) {
            $txtPath.Text = Join-Path $files[0] 'Vencord'
            $lblPathStatus.Text = "Dropped: $($files[0])"
            Play-Sound 'success'
        }
    }
})

Play-Sound 'boot'
$window.ShowDialog() | Out-Null
