package isabelle.byom

import isabelle._
import scala.language.unsafeNulls
import java.nio.ByteBuffer
import java.nio.charset.{CharacterCodingException, StandardCharsets}
import java.nio.file.{Files, LinkOption, StandardCopyOption}
import java.util.Base64

object Files_Command {
  private val nofollow = LinkOption.NOFOLLOW_LINKS
  private val max_file_bytes = 8 * 1024 * 1024
  private val projects = scala.collection.mutable.Map.empty[String, java.nio.file.Path]

  private def attr(attrs: Properties.T, key: String): String =
    Properties.get(attrs, key).getOrElse(error("Missing " + key))

  private def result(fields: Properties.Entry*): XML.Elem =
    XML.Elem(Markup("byom", fields.toList.map { case (key, value) =>
      key -> Base64.getEncoder.encodeToString(value.getBytes(StandardCharsets.UTF_8))
    }), Nil)

  private[byom] def write(root: java.nio.file.Path, name: String, data: Array[Byte]): XML.Elem = {
    val relative = java.nio.file.Path.of(name)
    if (name.isEmpty || relative.isAbsolute || name.split("/", -1).contains(".."))
      error("Expected a relative path without '..'")
    if (data.length > max_file_bytes) error("File exceeds 8 MiB")
    utf8(data)
    val base = root.toRealPath()
    val target = base.resolve(relative).normalize()
    if (target == base || !target.startsWith(base)) error("Invalid file path")
    var parent = base
    val parts = base.relativize(target).iterator()
    while (parts.hasNext) {
      parent = parent.resolve(parts.next())
      if (Files.isSymbolicLink(parent)) error("Symbolic links are not allowed")
      if (parent != target && !Files.exists(parent, nofollow)) {
        try { Files.createDirectory(parent) }
        catch { case _: java.nio.file.FileAlreadyExistsException => () }
        if (Files.isSymbolicLink(parent) || !Files.isDirectory(parent, nofollow))
          error("Expected a directory without symbolic links")
      }
    }
    val temp = Files.createTempFile(target.getParent, ".byom-", ".tmp")
    try {
      Files.write(temp, data)
      Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }
    finally Files.deleteIfExists(temp)
    result("path" -> target.toString)
  }

  private def placement[A](body: => A): A =
    try { body }
    catch {
      case ex: java.io.IOException => error("File placement failed: " + ex.getMessage)
      case ex: java.nio.file.InvalidPathException => error("Invalid file path: " + ex.getReason)
      case ex: SecurityException => error("File permission denied: " + ex.getMessage)
    }

  private def decode(text: String): Array[Byte] =
    try { Base64.getDecoder.decode(text) }
    catch { case _: IllegalArgumentException => error("Invalid base64 in file upload") }

  private def utf8(data: Array[Byte]): java.nio.CharBuffer =
    try { StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(data)) }
    catch { case _: CharacterCodingException => error("Expected UTF-8 in file upload") }

  private def write_upload(root: java.nio.file.Path, attrs: Properties.T, body: XML.Body): XML.Elem =
    placement {
      val encoded = body match {
        case Nil => ""
        case List(XML.Text(text)) => text
        case _ => error("Expected base64 file content")
      }
      if (encoded.length > ((max_file_bytes + 2) / 3) * 4) error("File exceeds 8 MiB")
      val path = attr(attrs, "path")
      write(root, utf8(decode(path)).toString, decode(encoded))
    }

  object Session_Write extends Server.Command("byom_write_file") {
    override val command_body: Server.Command_Body = {
      case (context, XML.Elem(Markup("file", attrs), body)) =>
        val id = Properties.get(attrs, "session_id").flatMap(UUID.unapply)
          .getOrElse(error("Missing or invalid session_id"))
        val session = context.server.the_session(id)
        write_upload(java.nio.file.Path.of(session.tmp_dir_name), attrs, body)
    }
  }

  // Explicit project ownership: the caller releases it after all builds/sessions using it stop.
  object Project_Create extends Server.Command("byom_create_project") {
    override val command_body: Server.Command_Body = { case (_, ()) => projects.synchronized {
      val id = UUID.random_string()
      val root = placement { Files.createTempDirectory("byom-project-") }
      projects(id) = root
      result("project_id" -> id, "dir" -> root.toString)
    }}
  }
  object Project_Write extends Server.Command("byom_write_project_file") {
    override val command_body: Server.Command_Body = {
      case (_, XML.Elem(Markup("file", attrs), body)) => projects.synchronized {
        val id = attr(attrs, "project_id")
        val root = projects.getOrElse(id, error("Unknown project"))
        write_upload(root, attrs, body)
      }
    }
  }
  object Project_Remove extends Server.Command("byom_remove_project") {
    override val command_body: Server.Command_Body = {
      case (_, XML.Elem(Markup("project", attrs), Nil)) => projects.synchronized {
        val id = attr(attrs, "project_id")
        val root = projects.getOrElse(id, error("Unknown project"))
        placement { Isabelle_System.rm_tree(Path.explode(root.toString)) }
        projects.remove(id)
        result("removed" -> id)
      }
    }
  }
}
class Commands extends Server.Commands(Files_Command.Session_Write,
  Files_Command.Project_Create, Files_Command.Project_Write, Files_Command.Project_Remove)
