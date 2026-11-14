require "digest"

# The release id of the app in public/: a digest of every file in it, so it
# changes with any change to the frontend and needs no version to bump. The
# service worker keeps one cache per release and serves a page from one
# release only (see public/sw.js). The digest is worked out again only when a
# file is added, removed or touched.
module Release
  ROOT = Rage.root.join("public")

  @signature = nil
  @id = nil

  def self.id
    files = Dir.glob("**/*", base: ROOT).sort.select { File.file?(ROOT.join(it)) }
    signature = files.map { |path| [path, File.mtime(ROOT.join(path)), File.size(ROOT.join(path))] }
    return @id if signature == @signature

    digest = Digest::SHA256.new
    files.each { |path| digest << path << "\0" << File.binread(ROOT.join(path)) << "\0" }
    @signature = signature
    @id = digest.hexdigest[0, 16]
  end
end
