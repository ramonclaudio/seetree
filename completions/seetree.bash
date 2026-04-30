_seetree() {
  local cur prev opts themes
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  opts="-h --help --version --once --detach --side --install-hook --apply --theme= -l --list"
  themes="claude mono gruvbox nord dracula tokyo-night catppuccin rose-pine solarized"

  case "$cur" in
    --theme=*)
      local prefix="--theme="
      COMPREPLY=( $(compgen -W "$themes" -P "$prefix" -- "${cur#$prefix}") )
      return 0
      ;;
    -*)
      COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
      return 0
      ;;
  esac

  COMPREPLY=( $(compgen -d -- "$cur") )
}
complete -F _seetree seetree
