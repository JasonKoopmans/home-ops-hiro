namespace PocketBridge.Core;

/// <summary>
/// Base for failures that map onto a specific <see cref="ExitCode"/>. Anything not
/// derived from this is treated as <see cref="ExitCode.Unexpected"/>.
/// </summary>
public class PocketBridgeException : Exception
{
    /// <summary>Initializes a new instance of the <see cref="PocketBridgeException"/> class.</summary>
    public PocketBridgeException()
        : this("The pocket-bridge pipeline failed.")
    {
    }

    /// <summary>Initializes a new instance of the <see cref="PocketBridgeException"/> class.</summary>
    /// <param name="message">Operator-facing message.</param>
    public PocketBridgeException(string message)
        : base(message)
    {
    }

    /// <summary>Initializes a new instance of the <see cref="PocketBridgeException"/> class.</summary>
    /// <param name="message">Operator-facing message.</param>
    /// <param name="innerException">Underlying cause.</param>
    public PocketBridgeException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    /// <summary>Exit code this failure maps to.</summary>
    public virtual ExitCode ExitCode => ExitCode.Unexpected;
}

/// <summary>The Obsidian vault could not be reached. Maps to <see cref="ExitCode.ObsidianUnavailable"/>.</summary>
public sealed class ObsidianUnavailableException : PocketBridgeException
{
    /// <summary>Initializes a new instance of the <see cref="ObsidianUnavailableException"/> class.</summary>
    public ObsidianUnavailableException()
        : base("The Obsidian Local REST API is unavailable.")
    {
    }

    /// <summary>Initializes a new instance of the <see cref="ObsidianUnavailableException"/> class.</summary>
    /// <param name="message">Operator-facing message.</param>
    public ObsidianUnavailableException(string message)
        : base(message)
    {
    }

    /// <summary>Initializes a new instance of the <see cref="ObsidianUnavailableException"/> class.</summary>
    /// <param name="message">Operator-facing message.</param>
    /// <param name="innerException">Underlying cause.</param>
    public ObsidianUnavailableException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    /// <inheritdoc/>
    public override ExitCode ExitCode => ExitCode.ObsidianUnavailable;
}

/// <summary>
/// Pocket rejected our credentials or the configured filter tag does not exist.
/// Maps to <see cref="ExitCode.PocketUnavailable"/>.
/// </summary>
public sealed class PocketUnavailableException : PocketBridgeException
{
    /// <summary>Initializes a new instance of the <see cref="PocketUnavailableException"/> class.</summary>
    public PocketUnavailableException()
        : base("The Hey Pocket API is unavailable.")
    {
    }

    /// <summary>Initializes a new instance of the <see cref="PocketUnavailableException"/> class.</summary>
    /// <param name="message">Operator-facing message.</param>
    public PocketUnavailableException(string message)
        : base(message)
    {
    }

    /// <summary>Initializes a new instance of the <see cref="PocketUnavailableException"/> class.</summary>
    /// <param name="message">Operator-facing message.</param>
    /// <param name="innerException">Underlying cause.</param>
    public PocketUnavailableException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    /// <inheritdoc/>
    public override ExitCode ExitCode => ExitCode.PocketUnavailable;
}

/// <summary>Configuration was missing or unusable. Maps to <see cref="ExitCode.ConfigError"/>.</summary>
public sealed class ConfigurationException : PocketBridgeException
{
    /// <summary>Initializes a new instance of the <see cref="ConfigurationException"/> class.</summary>
    public ConfigurationException()
        : base("pocket-bridge configuration is invalid.")
    {
    }

    /// <summary>Initializes a new instance of the <see cref="ConfigurationException"/> class.</summary>
    /// <param name="message">Operator-facing message.</param>
    public ConfigurationException(string message)
        : base(message)
    {
    }

    /// <summary>Initializes a new instance of the <see cref="ConfigurationException"/> class.</summary>
    /// <param name="message">Operator-facing message.</param>
    /// <param name="innerException">Underlying cause.</param>
    public ConfigurationException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    /// <inheritdoc/>
    public override ExitCode ExitCode => ExitCode.ConfigError;
}
