# Claude Code Agents

This directory contains custom agents for Claude Code that are synchronized across machines via git.

## Available Agents

### linux-cli-expert.md
Specialized Linux command-line expert for:
- Shell configuration optimization
- Tmux advanced configuration  
- Modern CLI tools integration
- Performance tuning
- System administration tasks

## Usage

These agents are automatically available in Claude Code and can be invoked using the Task tool with the appropriate `subagent_type` parameter.

## Adding New Agents

1. Create a new `.md` file in this directory
2. Follow the format of existing agents
3. Commit and sync via `conf2git`
4. Agent will be available across all machines

## Synchronization

These agents are part of the dotfiles repository and sync automatically with:
- `conf2git "message"` - Push changes
- `git2conf` - Pull latest changes