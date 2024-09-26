import os
from urllib.parse import unquote, urlparse

def is_local_link(link):
    return not bool(urlparse(link).netloc) and not link.startswith("mailto:")

def find_markdown_links(directory):
    markdown_links = []
    wiki_links = []
    for root, dirs, files in os.walk(directory):
        for file in files:
            if file.endswith(".md"):
                with open(os.path.join(root, file), "r") as f:
                    content = f.read()
                    lines = content.splitlines()
                    for i, line in enumerate(lines):
                        link_match = re.search(r"\[(.*?)\]\((.*?)\)", line)
                        if link_match and is_local_link(link_match.group(2)):
                            markdown_links.append(
                                (
                                    os.path.join(root, file),
                                    link_match.group(1),
                                    unquote(link_match.group(2)).split("#")[0],
                                    i + 1
                                )
                            )
                        wiki_link_match = re.search(r"\[\[(.*?)\]\]", line)
                        if wiki_link_match:
                            wiki_links.append(
                                (
                                    os.path.join(root, file),
                                    wiki_link_match.group(1),
                                    i + 1
                                )
                            )
    return (markdown_links, wiki_links)

import re
def check_markdown_links(markdown_links):
    missing_links = []
    for file_path, name, link, line in markdown_links:
        full_link = os.path.join(os.path.dirname(file_path), link)

        if not os.path.exists(full_link):
            missing_links.append((file_path, name, link, line))
    return missing_links

directory = "The Ansible Engineering Handbook/"
markdown_links, wiki_links = find_markdown_links(directory)

missing_links = check_markdown_links(markdown_links)

if missing_links:
    print("Broken Links:")
    for file_path, name, link, line in missing_links:
        print(f'  Line: {line}, File: "{file_path}", Link: "[{name}]({link})"')
    exit(2)

if len(wiki_links) > 0:
    print('Wikilinks (formatted like "[[Link]]") are not supported')
    for file_path, name, line in wiki_links:
        print(f'  Line: {line}, File: "{file_path}", Link: "[[{name}]]"')
